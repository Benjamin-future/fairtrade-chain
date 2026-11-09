import { createRouter, createWebHistory } from 'vue-router'
import HomeView from './views/HomeView.vue'
import BatchView from './views/BatchView.vue'
import DashboardView from './views/DashboardView.vue'

export default createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', component: HomeView },
    { path: '/batch/:id', component: BatchView, props: true },
    { path: '/dashboard', component: DashboardView },
  ],
  scrollBehavior: () => ({ top: 0 }),
})