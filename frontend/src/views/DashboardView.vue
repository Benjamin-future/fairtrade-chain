<script setup>
import { ref, reactive, computed, onMounted, onUnmounted } from 'vue'
import { ethers } from 'ethers'
import {
  contract, ROLE_NAMES, shortAddress, hasMetaMask,
  connectWallet, getConnectedAddress, getWriter, ensureNetwork, onWalletChange, friendlyError,
} from '../contract'

const ROLE = { None: 0, Cooperative: 1, Processor: 2, Exporter: 3, Auditor: 4 }
const pad = (n) => String(n).padStart(3, '0')

const roleGuide = [
  { title: 'Admin', text: 'Registers participants and sets the fair daily wage.' },
  { title: 'Cooperative', text: 'Creates batches at harvest and records what farm workers were paid.' },
  { title: 'Processor & Exporter', text: 'Add their step, record their workers’ pay and pass the batch on.' },
  { title: 'Auditor', text: 'Checks batches independently and attaches a certificate.' },
]

// ---------- State ----------
const metaMaskInstalled = hasMetaMask()
const account = ref(null)
const me = ref(null)
const connecting = ref(false)
const connectError = ref('')
const dataError = ref('')

const fairWage = ref(0)
const participants = ref([])
const batches = ref([])
const selectedBatchId = ref(null)

const status = reactive({ state: '', message: '', batchId: null })
let hideTimer = null
let stopListening = () => {}

// ---------- Forms ----------
const registerForm = reactive({ address: '', role: ROLE.Cooperative, name: '' })
const newWage = ref('')
const batchForm = reactive({ productName: '', origin: '', quantityKg: '' })
const stageForm = reactive({ location: '', description: '' })
const wageForm = reactive({ workerRef: '', daysWorked: '', amountKES: '' })
const handOverTo = ref('')
const auditForm = reactive({ batchId: '', ipfsCid: '', passed: true, notes: '', fileName: '', hash: '' })
const fileInput = ref(null)

// ---------- Derived ----------
const busy = computed(() => status.state === 'pending')
const isAdmin = computed(() => !!me.value?.isAdmin)
const isHolder = computed(
  () => !!me.value?.active && [ROLE.Cooperative, ROLE.Processor, ROLE.Exporter].includes(me.value.role)
)
const isAuditor = computed(() => !!me.value?.active && me.value.role === ROLE.Auditor)
const isUnregistered = computed(() => !!me.value && !me.value.isAdmin && !me.value.active)

const myBatches = computed(() =>
  batches.value.filter((b) => b.holder.toLowerCase() === account.value?.toLowerCase())
)
const selectedBatch = computed(() => myBatches.value.find((b) => b.id === selectedBatchId.value) || null)
const handOverOptions = computed(() =>
  participants.value.filter(
    (p) => p.active && p.role !== ROLE.Auditor && p.address.toLowerCase() !== account.value?.toLowerCase()
  )
)

const wagePreview = computed(() => {
  const days = Number(wageForm.daysWorked)
  const amount = Number(wageForm.amountKES)
  if (!days || !amount) return null
  const needed = fairWage.value * days
  return { fair: amount >= needed, needed }
})

// ---------- Loading ----------
async function loadChainData() {
  const [fw, count, addresses] = await Promise.all([
    contract.fairDailyWageKES(),
    contract.batchCount(),
    contract.getParticipants(),
  ])
  fairWage.value = Number(fw)

  participants.value = await Promise.all(
    [...addresses].map(async (address) => {
      const p = await contract.participants(address)
      return { address, name: p.name, role: Number(p.role), active: p.active }
    })
  )

  const ids = Array.from({ length: Number(count) }, (_, i) => i + 1)
  batches.value = await Promise.all(
    ids.map(async (id) => {
      const b = await contract.getBatch(id)
      return { id, name: b.productName, holder: b.currentHolder }
    })
  )
}

async function loadMe() {
  if (!account.value) {
    me.value = null
    return
  }
  const [owner, p] = await Promise.all([contract.owner(), contract.participants(account.value)])
  me.value = {
    name: p.name,
    role: Number(p.role),
    active: p.active,
    isAdmin: owner.toLowerCase() === account.value.toLowerCase(),
  }
}

async function refresh() {
  try {
    await Promise.all([loadChainData(), loadMe()])
    dataError.value = ''
  } catch (e) {
    console.error(e)
    dataError.value = 'Could not reach the blockchain right now. Check your connection and try again.'
  }
}

async function connect() {
  connecting.value = true
  connectError.value = ''
  try {
    account.value = await connectWallet()
    await refresh()
  } catch (e) {
    connectError.value = friendlyError(e)
  } finally {
    connecting.value = false
  }
}

async function handleWalletChange() {
  selectedBatchId.value = null
  account.value = await getConnectedAddress()
  await refresh()
}

onMounted(async () => {
  stopListening = onWalletChange(handleWalletChange)
  try {
    account.value = await getConnectedAddress()
  } catch (e) {
    console.error(e)
  }
  await refresh()
})

onUnmounted(() => {
  stopListening()
  clearTimeout(hideTimer)
})

// ---------- Sending transactions ----------
function showStatus(state, message, batchId = null) {
  clearTimeout(hideTimer)
  Object.assign(status, { state, message, batchId })
  if (state === 'success') hideTimer = setTimeout(() => (status.state = ''), 8000)
}

async function run(label, send, { batchId = null, onDone } = {}) {
  showStatus('pending', 'Confirm the transaction in MetaMask…')
  try {
    await ensureNetwork()
    const writer = await getWriter()
    const tx = await send(writer)
    showStatus('pending', 'Saving to the blockchain…')
    const receipt = await tx.wait()

    let id = batchId
    for (const log of receipt.logs) {
      try {
        const parsed = contract.interface.parseLog(log)
        if (parsed?.name === 'BatchCreated') id = Number(parsed.args.batchId)
      } catch { /* log from another contract */ }
    }

    await refresh()
    onDone?.(id)
    showStatus('success', `${label} saved to the blockchain.`, id)
  } catch (e) {
    console.error(e)
    showStatus('error', friendlyError(e))
  }
}

// ---------- Admin actions ----------
function registerParticipant() {
  const address = registerForm.address.trim()
  if (!ethers.isAddress(address)) return showStatus('error', 'That is not a valid wallet address.')
  run('Participant', (w) => w.registerParticipant(address, Number(registerForm.role), registerForm.name.trim()), {
    onDone: () => Object.assign(registerForm, { address: '', role: ROLE.Cooperative, name: '' }),
  })
}

function deactivate(p) {
  if (!window.confirm(`Deactivate ${p.name}? They will no longer be able to add records.`)) return
  run('Change', (w) => w.deactivateParticipant(p.address))
}

function setWage() {
  run('Fair daily wage', (w) => w.setFairDailyWage(Number(newWage.value)), {
    onDone: () => (newWage.value = ''),
  })
}

// ---------- Cooperative, processor and exporter actions ----------
function createBatch() {
  run(
    'Batch',
    (w) => w.createBatch(batchForm.productName.trim(), batchForm.origin.trim(), Number(batchForm.quantityKg)),
    {
      onDone: (id) => {
        Object.assign(batchForm, { productName: '', origin: '', quantityKg: '' })
        selectedBatchId.value = id
      },
    }
  )
}

function addStage() {
  const id = selectedBatchId.value
  run('Step', (w) => w.addStage(id, stageForm.location.trim(), stageForm.description.trim()), {
    batchId: id,
    onDone: () => Object.assign(stageForm, { location: '', description: '' }),
  })
}

function recordWage() {
  const id = selectedBatchId.value
  run(
    'Wage',
    (w) => w.recordWagePayment(id, wageForm.workerRef.trim(), Number(wageForm.daysWorked), Number(wageForm.amountKES)),
    { batchId: id, onDone: () => Object.assign(wageForm, { workerRef: '', daysWorked: '', amountKES: '' }) }
  )
}

function handOver() {
  const id = selectedBatchId.value
  const next = participants.value.find((p) => p.address === handOverTo.value)
  if (!window.confirm(`Hand batch No. ${pad(id)} to ${next?.name}? You won't be able to add to it afterwards.`)) return
  run('Handover', (w) => w.handOver(id, handOverTo.value), {
    batchId: id,
    onDone: () => {
      handOverTo.value = ''
      selectedBatchId.value = null
    },
  })
}

// ---------- Auditor actions ----------
async function onCertificateFile(event) {
  const file = event.target.files?.[0]
  if (!file) return
  const bytes = new Uint8Array(await file.arrayBuffer())
  auditForm.hash = ethers.keccak256(bytes)
  auditForm.fileName = file.name
}

function addAudit() {
  const id = Number(auditForm.batchId)
  run('Audit', (w) => w.addAudit(id, auditForm.ipfsCid.trim(), auditForm.hash, auditForm.passed, auditForm.notes.trim()), {
    batchId: id,
    onDone: () => {
      Object.assign(auditForm, { batchId: '', ipfsCid: '', passed: true, notes: '', fileName: '', hash: '' })
      if (fileInput.value) fileInput.value.value = ''
    },
  })
}
</script>

<template>
  <!-- Header -->
  <section class="dash-head">
    <div>
      <p class="eyebrow">Participant dashboard</p>
      <h1>Record your <span class="accent">part</span></h1>
      <p class="intro">
        Connect your wallet to add to a batch's record. Every entry is permanent and visible to buyers.
      </p>
    </div>

    <div class="account">
      <template v-if="!account">
        <span class="label">Not connected</span>
        <p class="account-text">Connect MetaMask to see the actions for your role.</p>
        <button class="btn-primary" type="button" :disabled="connecting || !metaMaskInstalled" @click="connect">
          {{ connecting ? 'Connecting…' : 'Connect wallet' }}
        </button>
        <p v-if="!metaMaskInstalled" class="error small">MetaMask isn't installed in this browser.</p>
        <p v-else-if="connectError" class="error small">{{ connectError }}</p>
      </template>

      <template v-else>
        <span class="label">Connected as</span>
        <strong>{{ me?.name || (isAdmin ? 'Admin' : 'Unregistered wallet') }}</strong>
        <span class="addr">{{ shortAddress(account) }}</span>
        <div class="roles">
          <span v-if="isAdmin" class="chip admin">Admin</span>
          <span v-if="me?.active" class="chip">{{ ROLE_NAMES[me.role] }}</span>
        </div>
        <p class="tip">To act as someone else, switch account in MetaMask.</p>
      </template>
    </div>
  </section>

  <p v-if="dataError" class="error banner">{{ dataError }}</p>

  <!-- Not connected: what each role does -->
  <section v-if="!account" class="group">
    <ol class="roles-grid">
      <li v-for="(r, i) in roleGuide" :key="r.title">
        <span class="step-no">0{{ i + 1 }}</span>
        <h3>{{ r.title }}</h3>
        <p>{{ r.text }}</p>
      </li>
    </ol>
  </section>

  <template v-else-if="me">
    <!-- Unregistered or deactivated -->
    <section v-if="isUnregistered" class="group">
      <div class="panel notice">
        <h3 class="panel-title">{{ me.name ? 'This wallet has been deactivated' : 'This wallet isn’t registered yet' }}</h3>
        <p class="panel-desc">
          {{ me.name
            ? 'The admin has turned off this participant, so it can no longer add records.'
            : 'Ask the admin to register this address with a role, then refresh the page.' }}
        </p>
        <code class="addr-full">{{ account }}</code>
      </div>
    </section>

    <!-- Admin -->
    <section v-if="isAdmin" class="group">
      <div class="group-head">
        <p class="eyebrow">Admin</p>
        <h2 class="section-title">Manage the network</h2>
      </div>

      <div class="panels">
        <div class="panel">
          <h3 class="panel-title">Register a participant</h3>
          <p class="panel-desc">Give a wallet address a role so it can add records.</p>
          <form @submit.prevent="registerParticipant">
            <label class="field">
              <span>Wallet address</span>
              <input v-model="registerForm.address" required placeholder="0x…" spellcheck="false" />
            </label>
            <label class="field">
              <span>Name</span>
              <input v-model="registerForm.name" required placeholder="e.g. Kirinyaga Farmers Co-op" />
            </label>
            <label class="field">
              <span>Role</span>
              <select v-model.number="registerForm.role">
                <option :value="ROLE.Cooperative">Cooperative</option>
                <option :value="ROLE.Processor">Processor</option>
                <option :value="ROLE.Exporter">Exporter</option>
                <option :value="ROLE.Auditor">Auditor</option>
              </select>
            </label>
            <button class="btn-primary" :disabled="busy">Register</button>
          </form>
        </div>

        <div class="panel">
          <h3 class="panel-title">Fair daily wage</h3>
          <p class="panel-desc">Every wage recorded from now on is checked against this rate.</p>
          <p class="big-figure">KES {{ fairWage.toLocaleString() }} <small>per day</small></p>
          <form @submit.prevent="setWage">
            <label class="field">
              <span>New rate (KES per day)</span>
              <input v-model="newWage" type="number" min="1" required />
            </label>
            <button class="btn-primary" :disabled="busy">Update rate</button>
          </form>
          <p class="hint">Past wage records keep the result they got when they were saved.</p>
        </div>

        <div class="panel wide">
          <h3 class="panel-title">Participants</h3>
          <p class="panel-desc">Read from the contract's participant list.</p>
          <p v-if="!participants.length" class="empty">No participants registered yet.</p>
          <div v-else class="table-wrap">
            <table>
              <thead>
                <tr><th>Name</th><th>Role</th><th>Address</th><th>Status</th><th></th></tr>
              </thead>
              <tbody>
                <tr v-for="p in participants" :key="p.address">
                  <td>{{ p.name }}</td>
                  <td>{{ ROLE_NAMES[p.role] }}</td>
                  <td class="mono">{{ shortAddress(p.address) }}</td>
                  <td>
                    <span :class="['badge', p.active ? 'ok' : 'bad']">{{ p.active ? 'Active' : 'Deactivated' }}</span>
                  </td>
                  <td class="right">
                    <button v-if="p.active" type="button" class="btn-ghost" :disabled="busy" @click="deactivate(p)">
                      Deactivate
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </section>

    <!-- Cooperative, processor, exporter -->
    <section v-if="isHolder" class="group">
      <div class="group-head">
        <p class="eyebrow">{{ ROLE_NAMES[me.role] }}</p>
        <h2 class="section-title">Your batches</h2>
      </div>

      <div class="panels">
        <div v-if="me.role === ROLE.Cooperative" class="panel">
          <h3 class="panel-title">Create a batch</h3>
          <p class="panel-desc">Register a new harvest. It starts with you, marked as Harvested.</p>
          <form @submit.prevent="createBatch">
            <label class="field">
              <span>Product</span>
              <input v-model="batchForm.productName" required placeholder="e.g. Arabica Coffee AA" />
            </label>
            <label class="field">
              <span>Origin</span>
              <input v-model="batchForm.origin" required placeholder="e.g. Nyeri, Kenya" />
            </label>
            <label class="field">
              <span>Quantity (kg)</span>
              <input v-model="batchForm.quantityKg" type="number" min="1" required />
            </label>
            <button class="btn-primary" :disabled="busy">Create batch</button>
          </form>
        </div>

        <div :class="['panel', { wide: me.role !== ROLE.Cooperative }]">
          <h3 class="panel-title">In your hands</h3>
          <p class="panel-desc">Choose a batch to add a step, record wages or pass it on.</p>
          <p v-if="!myBatches.length" class="empty">You're not holding any batches right now.</p>
          <div v-else class="batch-picker">
            <button
              v-for="b in myBatches"
              :key="b.id"
              type="button"
              :class="{ on: selectedBatchId === b.id }"
              @click="selectedBatchId = b.id"
            >
              <small>No. {{ pad(b.id) }}</small>
              {{ b.name }}
            </button>
          </div>
        </div>
      </div>

      <div v-if="selectedBatch" class="panels">
        <div class="panel wide working-on">
          <p>
            Working on <strong>No. {{ pad(selectedBatch.id) }} · {{ selectedBatch.name }}</strong>
          </p>
          <RouterLink :to="`/batch/${selectedBatch.id}`" class="link">View public page →</RouterLink>
        </div>

        <div class="panel">
          <h3 class="panel-title">Add a step</h3>
          <p class="panel-desc">Record what happened to the batch while you had it.</p>
          <form @submit.prevent="addStage">
            <label class="field">
              <span>What happened</span>
              <input v-model="stageForm.description" required placeholder="e.g. Washed and dried" />
            </label>
            <label class="field">
              <span>Where</span>
              <input v-model="stageForm.location" placeholder="e.g. Karatina" />
            </label>
            <button class="btn-primary" :disabled="busy">Add step</button>
          </form>
        </div>

        <div class="panel">
          <h3 class="panel-title">Record a wage</h3>
          <p class="panel-desc">Use an anonymous worker ID, never a real name.</p>
          <form @submit.prevent="recordWage">
            <label class="field">
              <span>Worker ID</span>
              <input v-model="wageForm.workerRef" required placeholder="e.g. W-014" />
            </label>
            <div class="row">
              <label class="field">
                <span>Days worked</span>
                <input v-model="wageForm.daysWorked" type="number" min="1" required />
              </label>
              <label class="field">
                <span>Paid (KES)</span>
                <input v-model="wageForm.amountKES" type="number" min="1" required />
              </label>
            </div>
            <p v-if="wagePreview" :class="['preview', wagePreview.fair ? 'ok' : 'bad']">
              {{ wagePreview.fair
                ? '✓ Meets the fair rate'
                : `✕ Below the fair rate: KES ${wagePreview.needed.toLocaleString()} needed for ${wageForm.daysWorked} days` }}
            </p>
            <button class="btn-primary" :disabled="busy">Record wage</button>
          </form>
          <p class="hint">Wages below the fair rate are still recorded, and the batch will show as Not Verified.</p>
        </div>

        <div class="panel">
          <h3 class="panel-title">Hand over</h3>
          <p class="panel-desc">Pass the batch to the next participant in the chain.</p>
          <form @submit.prevent="handOver">
            <label class="field">
              <span>Hand to</span>
              <select v-model="handOverTo" required>
                <option value="" disabled>Choose a participant</option>
                <option v-for="p in handOverOptions" :key="p.address" :value="p.address">
                  {{ p.name }} · {{ ROLE_NAMES[p.role] }}
                </option>
              </select>
            </label>
            <p class="hint">Once handed over, you can no longer add to this batch.</p>
            <button class="btn-primary" :disabled="busy || !handOverTo">Hand over</button>
          </form>
        </div>
      </div>
    </section>

    <!-- Auditor -->
    <section v-if="isAuditor" class="group">
      <div class="group-head">
        <p class="eyebrow">Auditor</p>
        <h2 class="section-title">Audit a batch</h2>
      </div>

      <div class="panel">
        <form @submit.prevent="addAudit">
          <div class="audit-cols">
            <div class="col">
              <label class="field">
                <span>Batch</span>
                <select v-model.number="auditForm.batchId" required>
                  <option value="" disabled>Choose a batch</option>
                  <option v-for="b in batches" :key="b.id" :value="b.id">No. {{ pad(b.id) }} · {{ b.name }}</option>
                </select>
              </label>

              <div class="field">
                <span>Certificate file</span>
                <label class="file">
                  <input ref="fileInput" type="file" @change="onCertificateFile" />
                  <strong>{{ auditForm.fileName || 'Choose a file' }}</strong>
                  <small>Only its fingerprint goes on the blockchain.</small>
                </label>
                <code v-if="auditForm.hash" class="hash">{{ auditForm.hash }}</code>
              </div>

              <label class="field">
                <span>IPFS reference</span>
                <input v-model="auditForm.ipfsCid" required placeholder="e.g. cert-nyeri-2026-01" />
              </label>
              <p class="hint">Uploading to IPFS comes in a later step. For now, type any reference for the file.</p>
            </div>

            <div class="col">
              <div class="field">
                <span>Result</span>
                <div class="segmented">
                  <label :class="['pass', { on: auditForm.passed }]">
                    <input v-model="auditForm.passed" type="radio" :value="true" />Passed
                  </label>
                  <label :class="['fail', { on: !auditForm.passed }]">
                    <input v-model="auditForm.passed" type="radio" :value="false" />Failed
                  </label>
                </div>
              </div>
              <label class="field">
                <span>Notes</span>
                <textarea v-model="auditForm.notes" placeholder="What did you check?"></textarea>
              </label>
              <button class="btn-primary" :disabled="busy || !auditForm.hash">Add audit</button>
            </div>
          </div>
        </form>
      </div>
    </section>
  </template>

  <!-- Transaction status -->
  <Transition name="toast">
    <div v-if="status.state" :class="['toast', status.state]" role="status">
      <span v-if="status.state === 'pending'" class="spinner"></span>
      <span v-else class="toast-icon">{{ status.state === 'success' ? '✓' : '!' }}</span>
      <div class="toast-body">
        <p>{{ status.message }}</p>
        <RouterLink v-if="status.state === 'success' && status.batchId" :to="`/batch/${status.batchId}`">
          View batch No. {{ pad(status.batchId) }} →
        </RouterLink>
      </div>
      <button v-if="status.state !== 'pending'" type="button" aria-label="Close" @click="status.state = ''">×</button>
    </div>
  </Transition>
</template>

<style scoped>
/* ---------- Header ---------- */
.dash-head { display: grid; grid-template-columns: 1fr 320px; gap: 40px; align-items: end; margin-bottom: 40px; }
.dash-head h1 { font-size: clamp(2rem, 4.5vw, 3rem); }
.intro { max-width: 420px; margin-top: 14px; font-size: .95rem; color: var(--muted); }

.account {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 20px;
  border: 1px solid var(--line);
  border-radius: 16px;
  background: var(--charcoal);
}
.account .label { font-size: .62rem; letter-spacing: .15em; text-transform: uppercase; color: var(--muted); }
.account strong { font-family: var(--serif); font-size: 1.2rem; }
.account-text { margin-bottom: 8px; font-size: .88rem; color: var(--muted); }
.addr { font-family: ui-monospace, monospace; font-size: .8rem; color: var(--muted); }
.roles { display: flex; gap: 6px; margin-top: 4px; }
.chip {
  padding: 2px 10px;
  border: 1px solid rgba(143, 191, 166, .4);
  border-radius: 999px;
  font-size: .62rem;
  letter-spacing: .14em;
  text-transform: uppercase;
  color: var(--mint);
}
.chip.admin { border-color: rgba(163, 28, 27, .6); color: var(--crimson-text); }
.tip { margin-top: 8px; padding-top: 10px; border-top: 1px solid var(--line); font-size: .75rem; color: var(--muted); }
.banner { margin-bottom: 24px; padding: 12px 16px; border: 1px solid rgba(163, 28, 27, .5); border-radius: 12px; }

/* ---------- Buttons ---------- */
.btn-primary {
  padding: 12px 22px;
  border: 0;
  border-radius: 999px;
  background: var(--crimson);
  color: var(--cream);
  font-size: .72rem;
  font-weight: 600;
  letter-spacing: .14em;
  text-transform: uppercase;
  cursor: pointer;
  transition: background .2s, opacity .2s;
}
.btn-primary:hover:not(:disabled) { background: #B8221F; }
.btn-primary:disabled { opacity: .45; cursor: not-allowed; }
.btn-ghost {
  padding: 7px 14px;
  border: 1px solid var(--line);
  border-radius: 999px;
  background: transparent;
  color: var(--cream);
  font-size: .65rem;
  letter-spacing: .1em;
  text-transform: uppercase;
  cursor: pointer;
  transition: border-color .2s;
}
.btn-ghost:hover:not(:disabled) { border-color: var(--crimson); }
.btn-ghost:disabled { opacity: .45; cursor: not-allowed; }
.link { font-size: .82rem; color: var(--mint); }

/* ---------- Groups and panels ---------- */
.group { margin-bottom: 48px; }
.group-head { margin-bottom: 18px; }
.group-head .section-title { margin-bottom: 0; }
.panels { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 16px; margin-bottom: 16px; }
.panel { padding: 24px; border: 1px solid var(--line); border-radius: 16px; background: var(--charcoal); }
.panel.wide { grid-column: 1 / -1; }
.panel.notice { border-color: rgba(163, 28, 27, .5); }
.panel-title { margin-bottom: 4px; font-family: var(--serif); font-size: 1.15rem; }
.panel-desc { margin-bottom: 18px; font-size: .82rem; color: var(--muted); }
.addr-full {
  display: block;
  padding: 10px 12px;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: rgba(6, 17, 12, .6);
  font-family: ui-monospace, monospace;
  font-size: .8rem;
  word-break: break-all;
}
.big-figure { margin-bottom: 16px; font-family: var(--serif); font-size: 1.8rem; }
.big-figure small { font-family: var(--sans); font-size: .8rem; color: var(--muted); }
.empty { padding: 24px; text-align: center; border: 1px dashed var(--line); border-radius: 12px; font-size: .88rem; color: var(--muted); }
.working-on { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; padding: 16px 24px; }
.working-on p { font-size: .9rem; color: var(--muted); }
.working-on strong { color: var(--cream); }

/* ---------- Forms ---------- */
form { display: flex; flex-direction: column; gap: 14px; }
.field { display: flex; flex-direction: column; gap: 6px; }
.field > span { font-size: .62rem; letter-spacing: .15em; text-transform: uppercase; color: var(--muted); }
input, select, textarea {
  width: 100%;
  padding: 11px 14px;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: rgba(6, 17, 12, .6);
  color: var(--cream);
  font-size: .9rem;
  outline: none;
  transition: border-color .2s;
}
input:focus, select:focus, textarea:focus { border-color: var(--crimson); }
input::placeholder, textarea::placeholder { color: rgba(154, 163, 157, .7); }
select option { background: var(--charcoal); }
textarea { min-height: 96px; resize: vertical; }
.row { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
.hint { margin-top: 10px; font-size: .76rem; color: var(--muted); }
form .hint { margin-top: -4px; }
.preview { padding: 8px 12px; border-radius: 10px; font-size: .8rem; }
.preview.ok { background: rgba(143, 191, 166, .12); color: var(--mint); }
.preview.bad { background: rgba(163, 28, 27, .15); color: var(--crimson-text); }

.batch-picker { display: flex; flex-wrap: wrap; gap: 8px; }
.batch-picker button {
  padding: 10px 16px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: transparent;
  color: var(--cream);
  text-align: left;
  cursor: pointer;
  transition: border-color .2s, background .2s;
}
.batch-picker button:hover { border-color: rgba(237, 230, 218, .3); }
.batch-picker button.on { border-color: var(--crimson); background: rgba(163, 28, 27, .12); }
.batch-picker small { display: block; font-size: .6rem; letter-spacing: .14em; text-transform: uppercase; color: var(--muted); }

.audit-cols { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; }
.col { display: flex; flex-direction: column; gap: 14px; }
.file {
  display: flex;
  flex-direction: column;
  gap: 2px;
  padding: 16px;
  border: 1px dashed rgba(237, 230, 218, .25);
  border-radius: 12px;
  cursor: pointer;
  transition: border-color .2s;
}
.file:hover { border-color: var(--mint); }
.file input { display: none; }
.file strong { font-size: .9rem; }
.file small { font-size: .75rem; color: var(--muted); }
.hash { font-family: ui-monospace, monospace; font-size: .7rem; color: var(--muted); word-break: break-all; }
.segmented { display: grid; grid-template-columns: 1fr 1fr; gap: 4px; padding: 4px; border: 1px solid var(--line); border-radius: 999px; }
.segmented label {
  padding: 8px;
  border-radius: 999px;
  text-align: center;
  font-size: .72rem;
  letter-spacing: .1em;
  text-transform: uppercase;
  color: var(--muted);
  cursor: pointer;
  transition: background .2s, color .2s;
}
.segmented input { display: none; }
.segmented .pass.on { background: var(--mint); color: var(--forest); }
.segmented .fail.on { background: var(--crimson); color: var(--cream); }

/* ---------- Participants table ---------- */
.table-wrap { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-size: .875rem; }
th, td { padding: 12px 14px; text-align: left; white-space: nowrap; border-bottom: 1px solid var(--line); }
th { font-size: .62rem; font-weight: 600; letter-spacing: .15em; text-transform: uppercase; color: var(--muted); }
tbody tr:last-child td { border-bottom: none; }
.mono { font-family: ui-monospace, monospace; font-size: .8rem; color: var(--muted); }
.right { text-align: right; }

/* ---------- Role guide ---------- */
.roles-grid { list-style: none; display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; }
.roles-grid li {
  padding: 22px 20px;
  border: 1px solid var(--line);
  border-radius: 14px;
  background: linear-gradient(180deg, rgba(23, 23, 23, .9), rgba(23, 23, 23, .35));
}
.step-no { font-family: var(--serif); font-size: 1.4rem; color: var(--crimson-text); }
.roles-grid h3 { margin: 10px 0 6px; font-size: .95rem; font-weight: 600; }
.roles-grid p { font-size: .82rem; line-height: 1.55; color: var(--muted); }

/* ---------- Toast ---------- */
.toast {
  position: fixed;
  z-index: 50;
  right: 24px;
  bottom: 24px;
  display: flex;
  gap: 12px;
  align-items: flex-start;
  max-width: 380px;
  padding: 14px 16px;
  border: 1px solid var(--line);
  border-radius: 14px;
  background: var(--charcoal);
  box-shadow: 0 20px 40px rgba(0, 0, 0, .45);
}
.toast.success { border-color: rgba(143, 191, 166, .6); }
.toast.error { border-color: rgba(163, 28, 27, .7); }
.toast-body { flex: 1; display: flex; flex-direction: column; gap: 4px; }
.toast-body p { font-size: .88rem; }
.toast-body a { font-size: .8rem; color: var(--mint); }
.toast > button { border: 0; background: none; color: var(--muted); font-size: 1.1rem; line-height: 1; cursor: pointer; }
.toast-icon { flex: none; display: grid; place-items: center; width: 22px; height: 22px; border-radius: 50%; font-size: .75rem; font-weight: 700; }
.toast.success .toast-icon { background: var(--mint); color: var(--forest); }
.toast.error .toast-icon { background: var(--crimson); color: var(--cream); }
.spinner { flex: none; width: 18px; height: 18px; margin-top: 1px; border: 2px solid var(--line); border-top-color: var(--cream); border-radius: 50%; animation: spin .8s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }
.toast-enter-active, .toast-leave-active { transition: opacity .25s, transform .25s; }
.toast-enter-from, .toast-leave-to { opacity: 0; transform: translateY(12px); }

/* ---------- Responsive ---------- */
@media (max-width: 900px) {
  .roles-grid { grid-template-columns: repeat(2, 1fr); }
}
@media (max-width: 860px) {
  .dash-head { grid-template-columns: 1fr; gap: 24px; }
  .audit-cols { grid-template-columns: 1fr; }
}
@media (max-width: 520px) {
  .roles-grid, .row { grid-template-columns: 1fr; }
  .toast { left: 16px; right: 16px; max-width: none; }
}
@media (prefers-reduced-motion: reduce) {
  .spinner { animation: none; }
}
</style>