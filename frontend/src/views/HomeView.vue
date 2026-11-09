<script setup>
import { ref, computed, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { contract } from '../contract'

const router = useRouter()

const batches = ref([])
const fairWage = ref(0)
const loading = ref(true)
const error = ref('')
const filter = ref('all')
const batchNumber = ref('')

const tabs = [
  { key: 'all', label: 'All' },
  { key: 'verified', label: 'Verified' },
  { key: 'pending', label: 'Not verified' },
]

const steps = [
  { title: 'Harvested', text: 'The cooperative registers the batch and records what each worker was paid.' },
  { title: 'Processed and shipped', text: 'Every handler adds their step before passing the batch on.' },
  { title: 'Audited', text: 'An independent auditor checks the batch and attaches a certificate.' },
  { title: 'Verified by you', text: 'Scan the QR code to see the full record. No one can alter it.' },
]

const verifiedCount = computed(() => batches.value.filter((b) => b.verified).length)
const totalWorkers = computed(() => batches.value.reduce((sum, b) => sum + b.workers, 0))
const fairWorkers = computed(() => batches.value.reduce((sum, b) => sum + b.fairWorkers, 0))
const latestVerified = computed(() => [...batches.value].reverse().find((b) => b.verified))

const filtered = computed(() => {
  if (filter.value === 'verified') return batches.value.filter((b) => b.verified)
  if (filter.value === 'pending') return batches.value.filter((b) => !b.verified)
  return batches.value
})

const pad = (n) => String(n).padStart(3, '0')

function goToBatch() {
  const n = Number(batchNumber.value)
  if (Number.isInteger(n) && n > 0) router.push(`/batch/${n}`)
}

onMounted(async () => {
  try {
    const [count, fw] = await Promise.all([contract.batchCount(), contract.fairDailyWageKES()])
    fairWage.value = Number(fw)

    const ids = Array.from({ length: Number(count) }, (_, i) => i + 1)
    batches.value = await Promise.all(
      ids.map(async (id) => {
        const [b, verified, stages, wages] = await Promise.all([
          contract.getBatch(id),
          contract.isFairTradeVerified(id),
          contract.getStages(id),
          contract.getWages(id),
        ])
        return {
          id,
          name: b.productName,
          kg: Number(b.quantityKg),
          verified,
          route: [...new Set(stages.map((s) => s.location).filter(Boolean))],
          stageCount: stages.length,
          workers: wages.length,
          fairWorkers: wages.filter((w) => w.meetsFairWage).length,
        }
      })
    )
  } catch (e) {
    console.error(e)
    error.value = 'Could not load batches right now. Please try again shortly.'
  } finally {
    loading.value = false
  }
})
</script>

<template>
  <!-- Cover -->
  <section class="cover">
    <img class="cover-img" src="/farm.jpg" alt="Tea farm in the Kenyan highlands" />
    <div class="cover-shade"></div>

    <div class="cover-body">
      <p class="eyebrow">From the farm to your cup</p>
      <h1><span class="accent">Traced</span><br />Differently</h1>
      <span class="rule"></span>
      <p class="cover-lead">
        See where your coffee and tea came from, who handled it, and whether the people who grew it were paid fairly.
      </p>

      <form class="verify" @submit.prevent="goToBatch">
        <input
          v-model="batchNumber"
          type="number"
          min="1"
          inputmode="numeric"
          placeholder="Enter batch number"
          aria-label="Batch number"
        />
        <button type="submit">Verify</button>
      </form>
      <p class="hint">Or scan the QR code on your pack.</p>
    </div>

    <RouterLink v-if="latestVerified" :to="`/batch/${latestVerified.id}`" class="cover-float">
      <span class="float-label"><i class="pulse"></i>Latest verified</span>
      <strong>{{ latestVerified.name }}</strong>
      <span class="muted">{{ latestVerified.route.join(' → ') }}</span>
    </RouterLink>
  </section>

  <!-- Stats -->
  <section class="stats">
    <div class="stat">
      <strong>{{ loading ? '—' : batches.length }}</strong>
      <span>Batches tracked</span>
    </div>
    <div class="stat">
      <strong>{{ loading ? '—' : verifiedCount }}</strong>
      <span>Fair Trade verified</span>
    </div>
    <div class="stat">
      <strong>{{ loading ? '—' : `${fairWorkers}/${totalWorkers}` }}</strong>
      <span>Workers paid fairly</span>
    </div>
    <div class="stat">
      <strong>{{ loading ? '—' : `KES ${fairWage.toLocaleString()}` }}</strong>
      <span>Fair daily wage</span>
    </div>
  </section>

  <!-- How it works -->
  <section class="how">
    <div class="how-head">
      <div>
        <p class="eyebrow">How it works</p>
        <h2 class="section-title">Every step, on the record</h2>
      </div>
      <p class="how-note">Once a step is recorded, nobody can edit or delete it — not the farm, not the exporter.</p>
    </div>
    <ol class="steps">
      <li v-for="(s, i) in steps" :key="s.title">
        <span class="step-no">0{{ i + 1 }}</span>
        <h3>{{ s.title }}</h3>
        <p>{{ s.text }}</p>
      </li>
    </ol>
  </section>

  <!-- Batches -->
  <section id="batches">
    <div class="batches-head">
      <div>
        <p class="eyebrow">The record</p>
        <h2 class="section-title">Batches</h2>
      </div>
      <div class="tabs">
        <button
          v-for="t in tabs"
          :key="t.key"
          type="button"
          :class="{ active: filter === t.key }"
          @click="filter = t.key"
        >
          {{ t.label }}
        </button>
      </div>
    </div>

    <div v-if="loading" class="batch-grid">
      <div v-for="n in 3" :key="n" class="skeleton"></div>
    </div>
    <p v-else-if="error" class="error">{{ error }}</p>
    <p v-else-if="!filtered.length" class="empty">No batches here yet.</p>

    <div v-else class="batch-grid">
      <RouterLink
        v-for="b in filtered"
        :key="b.id"
        :to="`/batch/${b.id}`"
        :class="['batch', { 'is-verified': b.verified }]"
      >
        <div class="batch-top">
          <span class="batch-no">No. {{ pad(b.id) }}</span>
          <span :class="['badge', b.verified ? 'ok' : 'bad']">{{ b.verified ? 'Verified' : 'Not verified' }}</span>
        </div>

        <h3>{{ b.name }}</h3>
        <p class="route">{{ b.route.join(' → ') }}</p>

        <div class="track">
          <span v-for="n in 3" :key="n" :class="{ on: n <= b.stageCount }"></span>
        </div>
        <div class="track-labels"><span>Farm</span><span>Processing</span><span>Export</span></div>

        <div class="batch-meta">
          <span>{{ b.kg.toLocaleString() }} kg</span>
          <span>{{ b.fairWorkers }}/{{ b.workers }} paid fairly</span>
        </div>
        <span class="batch-cta">View journey <i>→</i></span>
      </RouterLink>
    </div>
  </section>
</template>

<style scoped>
/* ---------- Cover ---------- */
.cover {
  position: relative;
  min-height: 520px;
  margin-bottom: 0;
  border-radius: 20px;
  overflow: hidden;
  display: flex;
  align-items: center;
  background: var(--charcoal);
}
.cover-img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
.cover-shade {
  position: absolute;
  inset: 0;
  background:
    radial-gradient(ellipse at 85% 115%, rgba(163, 28, 27, .45), transparent 55%),
    linear-gradient(90deg, rgba(6, 17, 12, .96) 0%, rgba(6, 17, 12, .8) 38%, rgba(6, 17, 12, .15) 75%),
    linear-gradient(0deg, rgba(6, 17, 12, .7), transparent 40%);
}
.cover-body { position: relative; z-index: 1; padding: 56px; max-width: 520px; }
.cover h1 { font-size: clamp(2.2rem, 5vw, 3.4rem); }
.rule { display: block; width: 44px; height: 2px; margin: 20px 0; background: var(--crimson); }
.cover-lead { max-width: 400px; font-size: .95rem; color: rgba(237, 230, 218, .78); }

.verify {
  display: flex;
  max-width: 380px;
  margin-top: 28px;
  padding: 4px;
  border: 1px solid rgba(237, 230, 218, .2);
  border-radius: 999px;
  background: rgba(6, 17, 12, .6);
  backdrop-filter: blur(8px);
  transition: border-color .2s;
}
.verify:focus-within { border-color: var(--crimson); }
.verify input {
  flex: 1;
  min-width: 0;
  padding: 0 16px;
  border: 0;
  outline: 0;
  background: transparent;
  color: var(--cream);
  font: inherit;
  font-size: .9rem;
  appearance: textfield;
  -moz-appearance: textfield;
}
.verify input::placeholder { color: var(--muted); }
.verify input::-webkit-outer-spin-button,
.verify input::-webkit-inner-spin-button { -webkit-appearance: none; margin: 0; }
.verify button {
  padding: 11px 22px;
  border: 0;
  border-radius: 999px;
  background: var(--crimson);
  color: var(--cream);
  font: inherit;
  font-size: .72rem;
  font-weight: 600;
  letter-spacing: .14em;
  text-transform: uppercase;
  cursor: pointer;
  transition: background .2s;
}
.verify button:hover { background: #B8221F; }
.hint { margin-top: 10px; font-size: .78rem; color: var(--muted); }

.cover-float {
  position: absolute;
  z-index: 1;
  right: 24px;
  bottom: 24px;
  width: 260px;
  padding: 16px 18px;
  display: flex;
  flex-direction: column;
  gap: 2px;
  border: 1px solid var(--line);
  border-radius: 14px;
  background: rgba(23, 23, 23, .72);
  backdrop-filter: blur(12px);
  transition: border-color .2s, transform .2s;
}
.cover-float:hover { border-color: var(--mint); transform: translateY(-2px); }
.float-label {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 4px;
  font-size: .65rem;
  letter-spacing: .15em;
  text-transform: uppercase;
  color: var(--mint);
}
.cover-float strong { font-family: var(--serif); font-size: 1.05rem; }
.cover-float .muted { font-size: .8rem; }
.pulse { width: 7px; height: 7px; border-radius: 50%; background: var(--mint); animation: pulse 2s infinite; }
@keyframes pulse {
  0% { box-shadow: 0 0 0 0 rgba(143, 191, 166, .6); }
  70% { box-shadow: 0 0 0 8px rgba(143, 191, 166, 0); }
  100% { box-shadow: 0 0 0 0 rgba(143, 191, 166, 0); }
}

/* ---------- Stats ---------- */
.stats {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  margin: 40px 0 64px;
  border-top: 1px solid var(--line);
  border-bottom: 1px solid var(--line);
}
.stat { padding: 24px 20px; border-left: 1px solid var(--line); }
.stat:first-child { border-left: 0; padding-left: 0; }
.stat strong { display: block; font-family: var(--serif); font-size: 1.8rem; line-height: 1.15; }
.stat span { font-size: .68rem; letter-spacing: .14em; text-transform: uppercase; color: var(--muted); }

/* ---------- How it works ---------- */
.how { margin-bottom: 64px; }
.how-head {
  display: flex;
  justify-content: space-between;
  align-items: flex-end;
  gap: 24px;
  flex-wrap: wrap;
  margin-bottom: 24px;
}
.how-head .section-title,
.batches-head .section-title { margin-bottom: 0; font-size: 1.6rem; }
.how-note { max-width: 320px; font-size: .85rem; color: var(--muted); }
.steps { list-style: none; display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; }
.steps li {
  padding: 22px 20px;
  border: 1px solid var(--line);
  border-radius: 14px;
  background: linear-gradient(180deg, rgba(23, 23, 23, .9), rgba(23, 23, 23, .35));
  transition: border-color .2s;
}
.steps li:hover { border-color: rgba(163, 28, 27, .6); }
.step-no { font-family: var(--serif); font-size: 1.4rem; color: var(--crimson-text); }
.steps h3 { margin: 10px 0 6px; font-size: .95rem; font-weight: 600; }
.steps p { font-size: .82rem; line-height: 1.55; color: var(--muted); }

/* ---------- Batches ---------- */
.batches-head {
  display: flex;
  justify-content: space-between;
  align-items: flex-end;
  gap: 16px;
  flex-wrap: wrap;
  margin-bottom: 20px;
}
.tabs { display: flex; gap: 4px; padding: 4px; border: 1px solid var(--line); border-radius: 999px; }
.tabs button {
  padding: 7px 14px;
  border: 0;
  border-radius: 999px;
  background: transparent;
  color: var(--muted);
  font: inherit;
  font-size: .7rem;
  letter-spacing: .1em;
  text-transform: uppercase;
  cursor: pointer;
  transition: background .2s, color .2s;
}
.tabs button.active { background: var(--cream); color: var(--forest); }
.tabs button:not(.active):hover { color: var(--cream); }

.batch-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 16px; }
.batch {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 22px;
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: 16px;
  background: var(--charcoal);
  transition: border-color .25s, transform .25s;
}
.batch::before { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 2px; background: var(--crimson); }
.batch.is-verified::before { background: var(--mint); }
.batch:hover { transform: translateY(-3px); border-color: rgba(237, 230, 218, .25); }
.batch-top { display: flex; justify-content: space-between; align-items: center; }
.batch-top .badge { margin-top: 0; }
.batch-no { font-size: .7rem; letter-spacing: .15em; text-transform: uppercase; color: var(--muted); }
.batch h3 { font-family: var(--serif); font-size: 1.25rem; line-height: 1.25; }
.route { font-size: .82rem; color: var(--muted); }

.track { display: grid; grid-template-columns: repeat(3, 1fr); gap: 4px; margin-top: 4px; }
.track span { height: 3px; border-radius: 2px; background: var(--line); }
.track span.on { background: var(--cream); }
.batch.is-verified .track span.on { background: var(--mint); }
.track-labels {
  display: flex;
  justify-content: space-between;
  font-size: .6rem;
  letter-spacing: .12em;
  text-transform: uppercase;
  color: var(--muted);
}

.batch-meta {
  display: flex;
  justify-content: space-between;
  margin-top: 4px;
  padding-top: 12px;
  border-top: 1px solid var(--line);
  font-size: .8rem;
  color: var(--muted);
}
.batch-cta {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: .7rem;
  letter-spacing: .12em;
  text-transform: uppercase;
}
.batch-cta i { font-style: normal; color: var(--crimson-text); transition: transform .25s; }
.batch:hover .batch-cta i { transform: translateX(4px); }

.skeleton {
  height: 240px;
  border-radius: 16px;
  background: linear-gradient(100deg, var(--charcoal) 30%, #23231f 50%, var(--charcoal) 70%);
  background-size: 200% 100%;
  animation: shimmer 1.4s infinite;
}
@keyframes shimmer { to { background-position: -200% 0; } }
.empty { padding: 40px; text-align: center; border: 1px dashed var(--line); border-radius: 16px; color: var(--muted); }

/* ---------- Responsive ---------- */
@media (max-width: 900px) {
  .steps { grid-template-columns: repeat(2, 1fr); }
}
@media (max-width: 760px) {
  .cover { min-height: 560px; align-items: flex-end; }
  .cover-shade {
    background:
      radial-gradient(ellipse at 85% 0%, rgba(163, 28, 27, .35), transparent 50%),
      linear-gradient(0deg, rgba(6, 17, 12, .97) 40%, rgba(6, 17, 12, .3) 100%);
  }
  .cover-body { padding: 28px 22px; }
  .cover-float { display: none; }
  .stats { grid-template-columns: repeat(2, 1fr); }
  .stat:nth-child(3) { border-left: 0; padding-left: 0; }
  .stat:nth-child(n + 3) { border-top: 1px solid var(--line); }
}
@media (max-width: 520px) {
  .steps { grid-template-columns: 1fr; }
}
@media (prefers-reduced-motion: reduce) {
  .pulse, .skeleton { animation: none; }
}
</style>