// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FairTradeSupplyChain
/// @notice Records a product batch's journey from farm to export, the wages paid
///         to workers, and audit certificates. Records can't be edited or deleted.
contract FairTradeSupplyChain {
    enum Role { None, Cooperative, Processor, Exporter, Auditor }

    struct Participant {
        string name;
        Role role;
        bool active;
    }

    struct Batch {
        uint256 id;
        string productName;   // e.g. "Arabica Coffee AA"
        string origin;        // e.g. "Nyeri, Kenya"
        uint256 quantityKg;
        address createdBy;
        address currentHolder;
        uint256 createdAt;
    }

    struct Stage {
        address handler;
        Role role;
        string location;
        string description;   // e.g. "Harvested", "Washed and dried"
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
        string ipfsCid;       // where the certificate is stored on IPFS
        bytes32 documentHash; // hash of the certificate file
        bool passed;
        string notes;
        uint256 timestamp;
    }

    address public owner;
    uint256 public fairDailyWageKES;
    uint256 public batchCount;

    mapping(address => Participant) public participants;
    mapping(uint256 => Batch) private batches;
    mapping(uint256 => Stage[]) private stages;
    mapping(uint256 => WagePayment[]) private wages;
    mapping(uint256 => Audit[]) private audits;

    event ParticipantRegistered(address indexed account, Role role, string name);
    event ParticipantDeactivated(address indexed account);
    event FairWageUpdated(uint256 oldWage, uint256 newWage);
    event BatchCreated(uint256 indexed batchId, string productName, address indexed createdBy);
    event StageAdded(uint256 indexed batchId, address indexed handler, string description);
    event BatchHandedOver(uint256 indexed batchId, address indexed from, address indexed to);
    event WageRecorded(uint256 indexed batchId, string workerRef, uint256 amountKES, bool meetsFairWage);
    event AuditAdded(uint256 indexed batchId, address indexed auditor, bool passed, string ipfsCid);

    error NotOwner();
    error NotAuthorised();
    error NotCurrentHolder();
    error BatchNotFound();
    error InvalidInput();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyRole(Role role) {
        Participant memory p = participants[msg.sender];
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

    constructor(uint256 _fairDailyWageKES) {
        owner = msg.sender;
        fairDailyWageKES = _fairDailyWageKES;
    }

    // ---------- Admin ----------

    function registerParticipant(address account, Role role, string calldata name) external onlyOwner {
        if (account == address(0) || role == Role.None || bytes(name).length == 0) revert InvalidInput();
        participants[account] = Participant(name, role, true);
        emit ParticipantRegistered(account, role, name);
    }

    function deactivateParticipant(address account) external onlyOwner {
        participants[account].active = false;
        emit ParticipantDeactivated(account);
    }

    function setFairDailyWage(uint256 newWageKES) external onlyOwner {
        if (newWageKES == 0) revert InvalidInput();
        emit FairWageUpdated(fairDailyWageKES, newWageKES);
        fairDailyWageKES = newWageKES;
    }

    // ---------- Supply chain ----------

    function createBatch(string calldata productName, string calldata origin, uint256 quantityKg)
        external onlyRole(Role.Cooperative) returns (uint256)
    {
        if (bytes(productName).length == 0 || quantityKg == 0) revert InvalidInput();
        batchCount++;
        uint256 id = batchCount;
        batches[id] = Batch(id, productName, origin, quantityKg, msg.sender, msg.sender, block.timestamp);
        stages[id].push(Stage(msg.sender, Role.Cooperative, origin, "Harvested", block.timestamp));
        emit BatchCreated(id, productName, msg.sender);
        emit StageAdded(id, msg.sender, "Harvested");
        return id;
    }

    function addStage(uint256 batchId, string calldata location, string calldata description)
        external batchExists(batchId) onlyHolder(batchId)
    {
        if (bytes(description).length == 0) revert InvalidInput();
        stages[batchId].push(Stage(msg.sender, participants[msg.sender].role, location, description, block.timestamp));
        emit StageAdded(batchId, msg.sender, description);
    }

    function handOver(uint256 batchId, address to) external batchExists(batchId) onlyHolder(batchId) {
        Participant memory next = participants[to];
        if (!next.active || next.role == Role.Auditor || to == msg.sender) revert InvalidInput();
        batches[batchId].currentHolder = to;
        emit BatchHandedOver(batchId, msg.sender, to);
    }

    function recordWagePayment(uint256 batchId, string calldata workerRef, uint256 daysWorked, uint256 amountKES)
        external batchExists(batchId) onlyHolder(batchId)
    {
        if (bytes(workerRef).length == 0 || daysWorked == 0 || amountKES == 0) revert InvalidInput();
        bool fair = amountKES >= fairDailyWageKES * daysWorked;
        wages[batchId].push(WagePayment(msg.sender, workerRef, daysWorked, amountKES, fair, block.timestamp));
        emit WageRecorded(batchId, workerRef, amountKES, fair);
    }

    function addAudit(uint256 batchId, string calldata ipfsCid, bytes32 documentHash, bool passed, string calldata notes)
        external batchExists(batchId) onlyRole(Role.Auditor)
    {
        if (bytes(ipfsCid).length == 0 || documentHash == bytes32(0)) revert InvalidInput();
        audits[batchId].push(Audit(msg.sender, ipfsCid, documentHash, passed, notes, block.timestamp));
        emit AuditAdded(batchId, msg.sender, passed, ipfsCid);
    }

    // ---------- Read (used by the QR page) ----------

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

    function verifyDocument(uint256 batchId, uint256 auditIndex, bytes32 documentHash)
        external view batchExists(batchId) returns (bool)
    {
        if (auditIndex >= audits[batchId].length) revert InvalidInput();
        return audits[batchId][auditIndex].documentHash == documentHash;
    }

    /// Fair Trade verified = at least one wage record, all wages fair,
    /// at least one audit, and all audits passed.
    function isFairTradeVerified(uint256 batchId) external view batchExists(batchId) returns (bool) {
        WagePayment[] storage w = wages[batchId];
        Audit[] storage a = audits[batchId];
        if (w.length == 0 || a.length == 0) return false;
        for (uint256 i = 0; i < w.length; i++) if (!w[i].meetsFairWage) return false;
        for (uint256 i = 0; i < a.length; i++) if (!a[i].passed) return false;
        return true;
    }
}