<template>
  <header class="nav">
    <RouterLink to="/" class="brand">Fair<span>Trace</span></RouterLink>
    <nav>
      <RouterLink to="/">Batches</RouterLink>
      <RouterLink to="/dashboard">Dashboard</RouterLink>
    </nav>
  </header>
  <main><RouterView /></main>
  <footer class="footer">© 2026 FairTrace</footer>
</template>

<style scoped>
.nav nav a.router-link-exact-active { color: var(--cream); }
</style>