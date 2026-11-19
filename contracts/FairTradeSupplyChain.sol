// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FairTradeSupplyChain (v2)
/// @notice Records a product batch's journey from farm to export, the wages paid
///         to workers, and audit certificates. Records can't be edited or deleted.
/// @dev v2 changes:
///      - Handovers and exports are written into the batch journey automatically
///      - Batch status (Harvested -> Processing -> InTransit -> Exported); Exported locks the batch
///      - Verification uses the LATEST audit verdict (all audits stay on record)
///      - O(1) fair-trade check via a running unfair-wage counter
///      - getBatchSummary(): everything the QR page needs in one call
///      - Admin: transferOwnership, reactivateParticipant, pause/unpause
///      - Stricter input validation and string length caps
contract FairTradeSupplyChain {
    // ---------- Types ----------

    enum Role { None, Cooperative, Processor, Exporter, Auditor }
    enum Status { Harvested, Processing, InTransit, Exported }

    struct Participant {
        string name;
        Role role;
        bool active;
    }

    struct Batch {
        uint256 id;
        string productName;
        string origin;
        uint256 quantityKg;
        address createdBy;
        address currentHolder;
        Status status;
        uint256 createdAt;
    }

    struct Stage {
        address handler;
        Role role;
        string location;
        string description;
        uint256 timestamp;
    }

    struct WagePayment {
        address payer;
        string workerRef;     // anonymised worker ID, never a real name
        uint256 daysWorked;
        uint256 amountKES;
        bool meetsFairWage;   // calculated by the contract
        uint256 timestamp;
    }

    struct Audit {
        address auditor;
        string ipfsCid;
        bytes32 documentHash;
        bool passed;
        string notes;
        uint256 timestamp;
    }

    // ---------- Limits ----------

    uint256 public constant MAX_SHORT_TEXT = 100;  // names, places, refs, CIDs
    uint256 public constant MAX_LONG_TEXT = 500;   // descriptions, audit notes
    uint256 public constant MAX_DAYS_PER_PAYMENT = 366;

    // ---------- State ----------

    address public owner;
    bool public paused;
    uint256 public fairDailyWageKES;
    uint256 public batchCount;

    mapping(address => Participant) public participants;
    address[] private participantList;
    mapping(uint256 => Batch) private batches;
    mapping(uint256 => Stage[]) private stages;
    mapping(uint256 => WagePayment[]) private wages;
    mapping(uint256 => Audit[]) private audits;
    mapping(uint256 => uint256) private unfairWageCount;

    // ---------- Events ----------

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event ParticipantRegistered(address indexed account, Role role, string name);
    event ParticipantDeactivated(address indexed account);
    event ParticipantReactivated(address indexed account);
    event FairWageUpdated(uint256 oldWage, uint256 newWage);
    event BatchCreated(uint256 indexed batchId, string productName, address indexed createdBy);
    event StageAdded(uint256 indexed batchId, address indexed handler, string description);
    event BatchHandedOver(uint256 indexed batchId, address indexed from, address indexed to);
    event BatchStatusChanged(uint256 indexed batchId, Status status);
    event WageRecorded(uint256 indexed batchId, string workerRef, uint256 amountKES, bool meetsFairWage);
    event AuditAdded(uint256 indexed batchId, address indexed auditor, bool passed, string ipfsCid);

    // ---------- Errors ----------

    error NotOwner();
    error NotAuthorised();
    error NotCurrentHolder();
    error BatchNotFound();
    error BatchLocked();
    error ContractPaused();
    error InvalidInput();

    // ---------- Modifiers ----------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier onlyRole(Role role) {
        Participant storage p = participants[msg.sender];
        if (!p.active || p.role != role) revert NotAuthorised();
        _;
    }

    modifier batchExists(uint256 batchId) {
        if (batchId == 0 || batchId > batchCount) revert BatchNotFound();
        _;
    }

    modifier onlyHolder(uint256 batchId) {
        if (batches[batchId].currentHolder != msg.sender) revert NotCurrentHolder();
        if (!participants[msg.sender].active) revert NotAuthorised();
        _;
    }

    modifier notExported(uint256 batchId) {
        if (batches[batchId].status == Status.Exported) revert BatchLocked();
        _;
    }

    constructor(uint256 _fairDailyWageKES) {
        if (_fairDailyWageKES == 0) revert InvalidInput();
        owner = msg.sender;
        fairDailyWageKES = _fairDailyWageKES;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ---------- Admin ----------

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0) || newOwner == owner) revert InvalidInput();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function pause() external onlyOwner {
        if (paused) revert InvalidInput();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!paused) revert InvalidInput();
        paused = false;
        emit Unpaused(msg.sender);
    }

    function registerParticipant(address account, Role role, string calldata name) external onlyOwner {
        if (account == address(0) || role == Role.None) revert InvalidInput();
        _requireText(name, MAX_SHORT_TEXT);
        if (participants[account].role == Role.None) participantList.push(account); // first time only
        participants[account] = Participant(name, role, true);
        emit ParticipantRegistered(account, role, name);
    }

    function deactivateParticipant(address account) external onlyOwner {
        Participant storage p = participants[account];
        if (p.role == Role.None || !p.active) revert InvalidInput();
        p.active = false;
        emit ParticipantDeactivated(account);
    }

    function reactivateParticipant(address account) external onlyOwner {
        Participant storage p = participants[account];
        if (p.role == Role.None || p.active) revert InvalidInput();
        p.active = true;
        emit ParticipantReactivated(account);
    }

    function setFairDailyWage(uint256 newWageKES) external onlyOwner {
        if (newWageKES == 0) revert InvalidInput();
        emit FairWageUpdated(fairDailyWageKES, newWageKES);
        fairDailyWageKES = newWageKES;
    }

    // ---------- Supply chain ----------

    function createBatch(string calldata productName, string calldata origin, uint256 quantityKg)
        external whenNotPaused onlyRole(Role.Cooperative) returns (uint256)
    {
        _requireText(productName, MAX_SHORT_TEXT);
        _requireText(origin, MAX_SHORT_TEXT);
        if (quantityKg == 0) revert InvalidInput();

        uint256 id = ++batchCount;
        batches[id] = Batch(id, productName, origin, quantityKg, msg.sender, msg.sender, Status.Harvested, block.timestamp);

        emit BatchCreated(id, productName, msg.sender);
        _addStage(id, origin, "Harvested");
        emit BatchStatusChanged(id, Status.Harvested);
        return id;
    }

    function addStage(uint256 batchId, string calldata location, string calldata description)
        external whenNotPaused batchExists(batchId) onlyHolder(batchId) notExported(batchId)
    {
        _requireText(location, MAX_SHORT_TEXT);
        _requireText(description, MAX_LONG_TEXT);
        _addStage(batchId, location, description);
    }

    /// @notice Pass the batch to the next participant. The handover is recorded in the journey,
    ///         and the status moves forward based on the receiver's role.
    function handOver(uint256 batchId, address to, string calldata location)
        external whenNotPaused batchExists(batchId) onlyHolder(batchId) notExported(batchId)
    {
        Participant storage next = participants[to];
        if (!next.active || next.role == Role.Auditor || to == msg.sender) revert InvalidInput();
        _requireText(location, MAX_SHORT_TEXT);

        Batch storage b = batches[batchId];
        b.currentHolder = to;
        emit BatchHandedOver(batchId, msg.sender, to);
        _addStage(batchId, location, string.concat("Handed over to ", next.name));

        Status newStatus = b.status;
        if (next.role == Role.Processor) newStatus = Status.Processing;
        else if (next.role == Role.Exporter) newStatus = Status.InTransit;
        if (newStatus != b.status) {
            b.status = newStatus;
            emit BatchStatusChanged(batchId, newStatus);
        }
    }

    /// @notice Final step: the exporter marks the batch as exported. The batch is then locked
    ///         (no more stages, handovers or wage records). Audits can still be added.
    function markExported(uint256 batchId, string calldata destination)
        external whenNotPaused batchExists(batchId) onlyHolder(batchId) notExported(batchId)
    {
        if (participants[msg.sender].role != Role.Exporter) revert NotAuthorised();
        _requireText(destination, MAX_SHORT_TEXT);

        batches[batchId].status = Status.Exported;
        _addStage(batchId, destination, "Exported");
        emit BatchStatusChanged(batchId, Status.Exported);
    }

    function recordWagePayment(uint256 batchId, string calldata workerRef, uint256 daysWorked, uint256 amountKES)
        external whenNotPaused batchExists(batchId) onlyHolder(batchId) notExported(batchId)
    {
        _requireText(workerRef, MAX_SHORT_TEXT);
        if (daysWorked == 0 || daysWorked > MAX_DAYS_PER_PAYMENT || amountKES == 0) revert InvalidInput();

        bool fair = amountKES >= fairDailyWageKES * daysWorked;
        if (!fair) unfairWageCount[batchId]++;

        wages[batchId].push(WagePayment(msg.sender, workerRef, daysWorked, amountKES, fair, block.timestamp));
        emit WageRecorded(batchId, workerRef, amountKES, fair);
    }

    function addAudit(uint256 batchId, string calldata ipfsCid, bytes32 documentHash, bool passed, string calldata notes)
        external whenNotPaused batchExists(batchId) onlyRole(Role.Auditor)
    {
        _requireText(ipfsCid, MAX_SHORT_TEXT);
        if (documentHash == bytes32(0) || bytes(notes).length > MAX_LONG_TEXT) revert InvalidInput();

        audits[batchId].push(Audit(msg.sender, ipfsCid, documentHash, passed, notes, block.timestamp));
        emit AuditAdded(batchId, msg.sender, passed, ipfsCid);
    }

    // ---------- Read ----------

    function getParticipants() external view returns (address[] memory) {
        return participantList;
    }

    function getBatch(uint256 batchId) external view batchExists(batchId) returns (Batch memory) {
        return batches[batchId];
    }

    function getStages(uint256 batchId) external view batchExists(batchId) returns (Stage[] memory) {
        return stages[batchId];
    }

    function getWages(uint256 batchId) external view batchExists(batchId) returns (WagePayment[] memory) {
        return wages[batchId];
    }

    function getAudits(uint256 batchId) external view batchExists(batchId) returns (Audit[] memory) {
        return audits[batchId];
    }

    /// @notice Everything the QR verification page needs, in a single call.
    function getBatchSummary(uint256 batchId)
        external
        view
        batchExists(batchId)
        returns (
            Batch memory batch,
            Stage[] memory journey,
            WagePayment[] memory wagePayments,
            Audit[] memory auditRecords,
            bool verified
        )
    {
        return (batches[batchId], stages[batchId], wages[batchId], audits[batchId], _isVerified(batchId));
    }

    function verifyDocument(uint256 batchId, uint256 auditIndex, bytes32 documentHash)
        external view batchExists(batchId) returns (bool)
    {
        if (auditIndex >= audits[batchId].length) revert InvalidInput();
        return audits[batchId][auditIndex].documentHash == documentHash;
    }

    /// @notice Verified = at least one wage record, every wage meets the fair wage,
    ///         and the most recent audit passed.
    function isFairTradeVerified(uint256 batchId) external view batchExists(batchId) returns (bool) {
        return _isVerified(batchId);
    }

    // ---------- Internal ----------

    function _isVerified(uint256 batchId) private view returns (bool) {
        uint256 auditCount = audits[batchId].length;
        if (wages[batchId].length == 0 || auditCount == 0) return false;
        if (unfairWageCount[batchId] != 0) return false;
        return audits[batchId][auditCount - 1].passed;
    }

    function _addStage(uint256 batchId, string memory location, string memory description) private {
        stages[batchId].push(Stage(msg.sender, participants[msg.sender].role, location, description, block.timestamp));
        emit StageAdded(batchId, msg.sender, description);
    }

    function _requireText(string calldata s, uint256 maxLen) private pure {
        uint256 len = bytes(s).length;
        if (len == 0 || len > maxLen) revert InvalidInput();
    }
}
