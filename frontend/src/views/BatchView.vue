<script setup>
import { ref, computed, onMounted } from 'vue'
import { ethers } from 'ethers'
import QRCode from 'qrcode'
import { contract, ROLE_NAMES, formatDate, participantName } from '../contract'

const props = defineProps({ id: String })

const batch = ref(null)
const stages = ref([])
const wages = ref([])
const audits = ref([])
const verified = ref(false)
const fairWage = ref(0)
const qr = ref('')
const loading = ref(true)
const error = ref('')
const copied = ref(false)
const checks = ref({})

const pad = (n) => String(n).padStart(3, '0')
const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`

const fairCount = computed(() => wages.value.filter((w) => w.fair).length)
const passedCount = computed(() => audits.value.filter((a) => a.passed).length)

const reasons = computed(() => [
  {
    label: 'Wage payments are on record',
    ok: wages.value.length > 0,
    detail: `${plural(wages.value.length, 'payment')} recorded`,
  },
  {
    label: 'Every worker was paid at least the fair rate',
    ok: wages.value.length > 0 && fairCount.value === wages.value.length,
    detail: `${fairCount.value} of ${wages.value.length} paid fairly`,
  },
  {
    label: 'An independent audit is on record',
    ok: audits.value.length > 0,
    detail: `${plural(audits.value.length, 'audit')} recorded`,
  },
  {
    label: 'Every audit passed',
    ok: audits.value.length > 0 && passedCount.value === audits.value.length,
    detail: `${passedCount.value} of ${audits.value.length} passed`,
  },
])

const verdictText = computed(() =>
  verified.value
    ? 'Every worker was paid at least the fair rate, and the batch passed an independent audit.'
    : 'At least one of the checks below has not been met yet.'
)

// The fair rate sits at two-thirds of the bar, so overpayment is still visible.
function barWidth(perDay) {
  if (!fairWage.value) return '0%'
  return `${Math.min(perDay / (fairWage.value * 1.5), 1) * 100}%`
}

async function copyLink() {
  try {
    await navigator.clipboard.writeText(window.location.href)
    copied.value = true
    setTimeout(() => (copied.value = false), 2000)
  } catch (e) {
    console.error(e)
  }
}

async function checkCertificate(index, event) {
  const file = event.target.files?.[0]
  if (!file) return
  checks.value[index] = 'checking'
  try {
    const bytes = new Uint8Array(await file.arrayBuffer())
    const hash = ethers.keccak256(bytes)
    const matches = await contract.verifyDocument(BigInt(props.id), index, hash)
    checks.value[index] = matches ? 'match' : 'mismatch'
  } catch (e) {
    console.error(e)
    checks.value[index] = 'failed'
  } finally {
    event.target.value = ''
  }
}

onMounted(async () => {
  try {
    const id = BigInt(props.id)
    const [b, s, w, a, v, fw] = await Promise.all([
      contract.getBatch(id),
      contract.getStages(id),
      contract.getWages(id),
      contract.getAudits(id),
      contract.isFairTradeVerified(id),
      contract.fairDailyWageKES(),
    ])

    fairWage.value = Number(fw)
    verified.value = v

    batch.value = {
      name: b.productName,
      origin: b.origin,
      kg: Number(b.quantityKg),
      created: formatDate(b.createdAt),
      holder: await participantName(b.currentHolder),
    }

    stages.value = await Promise.all(
      s.map(async (st) => ({
        who: await participantName(st.handler),
        role: ROLE_NAMES[Number(st.role)],
        location: st.location,
        description: st.description,
        date: formatDate(st.timestamp),
      }))
    )

    wages.value = await Promise.all(
      w.map(async (x) => {
        const days = Number(x.daysWorked)
        const amount = Number(x.amountKES)
        return {
          worker: x.workerRef,
          payer: await participantName(x.payer),
          days,
          amount,
          perDay: Math.round(amount / days),
          fair: x.meetsFairWage,
        }
      })
    )

    audits.value = await Promise.all(
      a.map(async (x) => ({
        auditor: await participantName(x.auditor),
        cid: x.ipfsCid,
        hash: x.documentHash,
        passed: x.passed,
        notes: x.notes,
        date: formatDate(x.timestamp),
      }))
    )

    qr.value = await QRCode.toDataURL(window.location.href, {
      width: 400,
      margin: 1,
      color: { dark: '#06110C', light: '#EDE6DA' },
    })
  } catch (e) {
    console.error(e)
    error.value = 'This batch number does not exist, or the record could not be reached right now.'
  } finally {
    loading.value = false
  }
})
</script>

<template>
  <RouterLink to="/" class="back">← All batches</RouterLink>

  <!-- Loading -->
  <div v-if="loading">
    <div class="sk sk-title"></div>
    <div class="sk sk-line"></div>
    <div class="sk sk-block"></div>
  </div>

  <!-- Not found -->
  <div v-else-if="error" class="notfound">
    <p class="eyebrow">Batch No. {{ pad(id) }}</p>
    <h1>Not found</h1>
    <p class="muted">{{ error }}</p>
    <RouterLink to="/" class="btn">Back to all batches</RouterLink>
  </div>

  <template v-else>
    <!-- Header -->
    <header class="head">
      <div>
        <p class="eyebrow">Batch No. {{ pad(id) }} · {{ batch.origin }}</p>
        <h1>{{ batch.name }}</h1>
        <span class="rule"></span>

        <dl class="facts">
          <div><dt>Quantity</dt><dd>{{ batch.kg.toLocaleString() }} kg</dd></div>
          <div><dt>Registered</dt><dd>{{ batch.created }}</dd></div>
          <div><dt>Now with</dt><dd>{{ batch.holder }}</dd></div>
        </dl>

        <div :class="['verdict', verified ? 'ok' : 'bad']">
          <span class="verdict-icon">{{ verified ? '✓' : '!' }}</span>
          <div>
            <strong>{{ verified ? 'Fair Trade Verified' : 'Not Verified' }}</strong>
            <p>{{ verdictText }}</p>
          </div>
        </div>
      </div>

      <aside class="qr-card">
        <img :src="qr" alt="QR code for this batch" />
        <p class="qr-label">Scan to verify</p>
        <div class="qr-actions">
          <button type="button" @click="copyLink">{{ copied ? 'Copied' : 'Copy link' }}</button>
          <a :href="qr" :download="`fairtrace-batch-${pad(id)}.png`">Download</a>
        </div>
      </aside>
    </header>

    <!-- Stats -->
    <section class="stats">
      <div class="stat"><strong>{{ stages.length }}</strong><span>Stages recorded</span></div>
      <div class="stat"><strong>{{ fairCount }}/{{ wages.length }}</strong><span>Workers paid fairly</span></div>
      <div class="stat"><strong>{{ passedCount }}/{{ audits.length }}</strong><span>Audits passed</span></div>
      <div class="stat"><strong>KES {{ fairWage.toLocaleString() }}</strong><span>Fair daily wage</span></div>
    </section>

    <!-- Journey + checks -->
    <div class="split">
      <section>
        <p class="eyebrow">The journey</p>
        <h2 class="section-title">From farm to export</h2>
        <ol class="timeline">
          <li v-for="(s, i) in stages" :key="i" :class="{ last: i === stages.length - 1 }">
            <span class="node">{{ String(i + 1).padStart(2, '0') }}</span>
            <div class="stage">
              <div class="stage-top">
                <h3>{{ s.description }}</h3>
                <span class="chip">{{ s.role }}</span>
              </div>
              <p>{{ s.who }}</p>
              <p class="muted small">{{ s.location }} · {{ s.date }}</p>
            </div>
          </li>
        </ol>
      </section>

      <aside class="why">
        <p class="eyebrow">Why this result</p>
        <h2 class="section-title">The checks</h2>
        <ul class="checks">
          <li v-for="r in reasons" :key="r.label" :class="r.ok ? 'ok' : 'bad'">
            <span class="tick">{{ r.ok ? '✓' : '✕' }}</span>
            <div>
              <p>{{ r.label }}</p>
              <span class="detail">{{ r.detail }}</span>
            </div>
          </li>
        </ul>
        <p class="why-note">These checks are worked out by the smart contract itself. Nobody can type in a result.</p>
      </aside>
    </div>

    <!-- Wages -->
    <section class="block">
      <div class="block-head">
        <div>
          <p class="eyebrow">Wages</p>
          <h2 class="section-title">What workers were paid</h2>
        </div>
        <p class="muted small">Fair rate: <strong>KES {{ fairWage.toLocaleString() }}</strong> per day</p>
      </div>

      <p v-if="!wages.length" class="empty">No wage records yet.</p>
      <div v-else class="table-card">
        <table>
          <thead>
            <tr>
              <th>Worker</th>
              <th>Paid by</th>
              <th>Days</th>
              <th>Total (KES)</th>
              <th>Per day vs fair rate</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(w, i) in wages" :key="i">
              <td class="worker">{{ w.worker }}</td>
              <td>{{ w.payer }}</td>
              <td>{{ w.days }}</td>
              <td>{{ w.amount.toLocaleString() }}</td>
              <td>
                <div class="rate">
                  <span class="rate-num">{{ w.perDay.toLocaleString() }}</span>
                  <span class="rate-bar">
                    <i :class="w.fair ? 'ok' : 'bad'" :style="{ width: barWidth(w.perDay) }"></i>
                    <b title="Fair rate"></b>
                  </span>
                </div>
              </td>
              <td>
                <span :class="['badge', w.fair ? 'ok' : 'bad']">{{ w.fair ? 'Fair' : 'Below fair rate' }}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="note">Workers are shown by an anonymous ID only, to protect their privacy.</p>
    </section>

    <!-- Audits -->
    <section class="block">
      <div class="block-head">
        <div>
          <p class="eyebrow">Audits</p>
          <h2 class="section-title">Independent checks</h2>
        </div>
      </div>

      <p v-if="!audits.length" class="empty">
        No audits yet. This batch can't be verified until an independent auditor checks it.
      </p>
      <div v-else class="audit-grid">
        <article v-for="(a, i) in audits" :key="i" class="audit">
          <div class="audit-top">
            <h3>{{ a.auditor }}</h3>
            <span :class="['badge', a.passed ? 'ok' : 'bad']">{{ a.passed ? 'Passed' : 'Failed' }}</span>
          </div>
          <p>{{ a.notes }}</p>
          <p class="muted small">{{ a.date }}</p>

          <div class="hash">
            <span>Certificate fingerprint</span>
            <code>{{ a.hash }}</code>
          </div>

          <div class="audit-actions">
            <label class="btn-ghost">
              Check a certificate file
              <input type="file" hidden @change="checkCertificate(i, $event)" />
            </label>
            <a :href="`https://ipfs.io/ipfs/${a.cid}`" target="_blank" rel="noopener" class="link">View on IPFS →</a>
          </div>

          <p v-if="checks[i]" :class="['check-result', checks[i]]">
            <template v-if="checks[i] === 'checking'">Checking…</template>
            <template v-else-if="checks[i] === 'match'">✓ This file matches the certificate on record.</template>
            <template v-else-if="checks[i] === 'mismatch'">✕ This file does not match. It may have been changed.</template>
            <template v-else>Could not check this file. Please try again.</template>
          </p>
        </article>
      </div>
    </section>
  </template>
</template>

<style scoped>
/* ---------- Header ---------- */
.head { display: grid; grid-template-columns: 1fr 240px; gap: 48px; align-items: start; margin-bottom: 8px; }
.head h1 { font-size: clamp(1.9rem, 4.5vw, 3rem); }
.rule { display: block; width: 44px; height: 2px; margin: 18px 0; background: var(--crimson); }

.facts { display: flex; flex-wrap: wrap; gap: 12px 36px; }
.facts dt { font-size: .65rem; letter-spacing: .15em; text-transform: uppercase; color: var(--muted); }
.facts dd { font-size: .92rem; }

.verdict { display: flex; gap: 16px; align-items: flex-start; max-width: 560px; margin-top: 28px; padding: 18px 20px; border-radius: 14px; }
.verdict.ok { background: rgba(143, 191, 166, .08); border: 1px solid rgba(143, 191, 166, .45); }
.verdict.bad { background: rgba(163, 28, 27, .1); border: 1px solid rgba(163, 28, 27, .6); }
.verdict-icon { flex: none; display: grid; place-items: center; width: 36px; height: 36px; border-radius: 50%; font-weight: 700; }
.verdict.ok .verdict-icon { background: var(--mint); color: var(--forest); }
.verdict.bad .verdict-icon { background: var(--crimson); color: var(--cream); }
.verdict strong { font-family: var(--serif); font-size: 1.2rem; }
.verdict.ok strong { color: var(--mint); }
.verdict.bad strong { color: var(--crimson-text); }
.verdict p { margin-top: 2px; font-size: .88rem; color: rgba(237, 230, 218, .8); }

.qr-card { padding: 18px; text-align: center; border: 1px solid var(--line); border-radius: 16px; background: var(--charcoal); }
.qr-card img { display: block; width: 100%; max-width: 200px; aspect-ratio: 1; margin: 0 auto; border-radius: 10px; }
.qr-label { margin-top: 10px; font-size: .62rem; letter-spacing: .18em; text-transform: uppercase; color: var(--muted); }
.qr-actions { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 12px; }
.qr-actions button,
.qr-actions a {
  padding: 8px 0;
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
.qr-actions button:hover,
.qr-actions a:hover { border-color: var(--crimson); }

/* ---------- Stats ---------- */
.stats {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  margin: 40px 0 56px;
  border-top: 1px solid var(--line);
  border-bottom: 1px solid var(--line);
}
.stat { padding: 22px 20px; border-left: 1px solid var(--line); }
.stat:first-child { border-left: 0; padding-left: 0; }
.stat strong { display: block; font-family: var(--serif); font-size: 1.6rem; line-height: 1.15; }
.stat span { font-size: .66rem; letter-spacing: .14em; text-transform: uppercase; color: var(--muted); }

/* ---------- Journey + checks ---------- */
.split { display: grid; grid-template-columns: 1.5fr 1fr; gap: 40px; align-items: start; margin-bottom: 56px; }
.split > section { margin-bottom: 0; }

.timeline { list-style: none; }
.timeline li { position: relative; display: grid; grid-template-columns: 44px 1fr; gap: 16px; padding-bottom: 18px; }
.timeline li:not(.last)::before {
  content: '';
  position: absolute;
  left: 21px;
  top: 44px;
  bottom: 0;
  width: 2px;
  background: linear-gradient(var(--crimson), rgba(163, 28, 27, .15));
}
.node {
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  border: 1px solid rgba(163, 28, 27, .6);
  border-radius: 50%;
  background: var(--forest);
  color: var(--crimson-text);
  font-family: var(--serif);
  font-size: .9rem;
}
.last .node { background: var(--crimson); border-color: var(--crimson); color: var(--cream); }
.stage { padding: 14px 18px; border: 1px solid var(--line); border-radius: 14px; background: var(--charcoal); }
.stage-top { display: flex; justify-content: space-between; align-items: center; gap: 10px; flex-wrap: wrap; }
.stage h3 { font-family: var(--serif); font-size: 1.05rem; }
.stage p { font-size: .9rem; }
.chip {
  padding: 2px 8px;
  border: 1px solid rgba(143, 191, 166, .35);
  border-radius: 999px;
  font-size: .6rem;
  letter-spacing: .14em;
  text-transform: uppercase;
  color: var(--mint);
}

.why {
  position: sticky;
  top: 24px;
  padding: 22px;
  border: 1px solid var(--line);
  border-radius: 16px;
  background: linear-gradient(180deg, rgba(23, 23, 23, .95), rgba(23, 23, 23, .5));
}
.checks { list-style: none; display: grid; gap: 14px; }
.checks li { display: flex; gap: 12px; align-items: flex-start; }
.tick { flex: none; display: grid; place-items: center; width: 22px; height: 22px; border-radius: 50%; font-size: .7rem; font-weight: 700; }
.checks li.ok .tick { background: rgba(143, 191, 166, .18); color: var(--mint); }
.checks li.bad .tick { background: rgba(163, 28, 27, .2); color: var(--crimson-text); }
.checks p { font-size: .88rem; line-height: 1.4; }
.detail { font-size: .75rem; color: var(--muted); }
.why-note { margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--line); font-size: .75rem; color: var(--muted); }

/* ---------- Wages ---------- */
.block { margin-bottom: 56px; }
.block-head { display: flex; justify-content: space-between; align-items: flex-end; gap: 16px; flex-wrap: wrap; margin-bottom: 18px; }
.block-head .section-title { margin-bottom: 0; }
.block-head strong { color: var(--cream); }

.table-card { overflow-x: auto; border: 1px solid var(--line); border-radius: 16px; background: var(--charcoal); }
table { width: 100%; border-collapse: collapse; font-size: .875rem; }
th, td { padding: 13px 18px; text-align: left; white-space: nowrap; border-bottom: 1px solid var(--line); }
th { font-size: .62rem; font-weight: 600; letter-spacing: .15em; text-transform: uppercase; color: var(--muted); }
tbody tr:last-child td { border-bottom: none; }
tbody tr:hover { background: rgba(237, 230, 218, .03); }
.worker { font-family: ui-monospace, monospace; font-size: .8rem; }

.rate { display: flex; align-items: center; gap: 10px; }
.rate-num { min-width: 44px; }
.rate-bar { position: relative; width: 110px; height: 4px; border-radius: 2px; background: var(--line); }
.rate-bar i { position: absolute; top: 0; bottom: 0; left: 0; border-radius: 2px; }
.rate-bar i.ok { background: var(--mint); }
.rate-bar i.bad { background: var(--crimson-text); }
.rate-bar b { position: absolute; left: 66.67%; top: -4px; bottom: -4px; width: 1px; background: var(--cream); opacity: .6; }
.note { margin-top: 10px; font-size: .75rem; color: var(--muted); }
.empty { padding: 32px; text-align: center; border: 1px dashed var(--line); border-radius: 16px; color: var(--muted); }

/* ---------- Audits ---------- */
.audit-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 16px; }
.audit { display: flex; flex-direction: column; gap: 8px; padding: 22px; border: 1px solid var(--line); border-radius: 16px; background: var(--charcoal); }
.audit-top { display: flex; justify-content: space-between; align-items: center; gap: 12px; }
.audit h3 { font-family: var(--serif); font-size: 1.1rem; }
.audit > p { font-size: .9rem; }
.hash { margin-top: 6px; padding: 10px 12px; border: 1px solid var(--line); border-radius: 10px; background: rgba(6, 17, 12, .6); }
.hash span { display: block; margin-bottom: 4px; font-size: .6rem; letter-spacing: .15em; text-transform: uppercase; color: var(--muted); }
.hash code { font-family: ui-monospace, monospace; font-size: .72rem; word-break: break-all; color: rgba(237, 230, 218, .85); }
.audit-actions { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; margin-top: 6px; }
.btn-ghost {
  padding: 8px 14px;
  border: 1px solid var(--line);
  border-radius: 999px;
  font-size: .65rem;
  letter-spacing: .1em;
  text-transform: uppercase;
  cursor: pointer;
  transition: border-color .2s;
}
.btn-ghost:hover { border-color: var(--mint); }
.link { font-size: .8rem; color: var(--mint); }
.check-result { padding: 8px 12px; border-radius: 10px; font-size: .82rem; }
.check-result.match { background: rgba(143, 191, 166, .12); color: var(--mint); }
.check-result.mismatch,
.check-result.failed { background: rgba(163, 28, 27, .15); color: var(--crimson-text); }
.check-result.checking { color: var(--muted); }

/* ---------- Loading and not found ---------- */
.notfound { max-width: 480px; padding: 48px 0; }
.notfound h1 { margin-bottom: 10px; }
.btn {
  display: inline-block;
  margin-top: 20px;
  padding: 10px 20px;
  border-radius: 999px;
  background: var(--crimson);
  font-size: .72rem;
  letter-spacing: .12em;
  text-transform: uppercase;
}
.sk {
  margin-bottom: 14px;
  border-radius: 12px;
  background: linear-gradient(100deg, var(--charcoal) 30%, #23231f 50%, var(--charcoal) 70%);
  background-size: 200% 100%;
  animation: shimmer 1.4s infinite;
}
.sk-title { width: 60%; height: 48px; }
.sk-line { width: 35%; height: 16px; }
.sk-block { height: 280px; }
@keyframes shimmer { to { background-position: -200% 0; } }

/* ---------- Responsive ---------- */
@media (max-width: 860px) {
  .head { grid-template-columns: 1fr; gap: 28px; }
  .qr-card { max-width: 260px; }
  .split { grid-template-columns: 1fr; }
  .why { position: static; }
}
@media (max-width: 760px) {
  .stats { grid-template-columns: repeat(2, 1fr); }
  .stat:nth-child(3) { border-left: 0; padding-left: 0; }
  .stat:nth-child(n + 3) { border-top: 1px solid var(--line); }
}
@media (prefers-reduced-motion: reduce) {
  .sk { animation: none; }
}
</style>