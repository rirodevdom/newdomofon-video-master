import { createRouter, createWebHistory } from 'vue-router';
import { useAuthStore } from './stores/auth';
import LoginView from './views/LoginView.vue';
import DashboardView from './views/DashboardView.vue';
import CamerasView from './views/CamerasView.vue';
import DevicesView from './views/DevicesView.vue';
import NodesView from './views/NodesView.vue';
import PlayerView from './views/PlayerView.vue';
import HikvisionChannelsView from './views/HikvisionChannelsView.vue';
import HikvisionPlayerView from './views/HikvisionPlayerView.vue';
import AdminView from './views/AdminView.vue';

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', component: LoginView, meta: { public: true } },
    { path: '/', component: DashboardView },
    { path: '/devices', component: DevicesView },
    { path: '/cameras', component: CamerasView },
    { path: '/hikvision', component: HikvisionChannelsView, name: 'hikvision-channels' },
    { path: '/nodes', component: NodesView },
    { path: '/cameras/:id', component: PlayerView, name: 'camera-player' },
    { path: '/hikvision/:id', component: HikvisionPlayerView, name: 'hikvision-player' },
    { path: '/admin', component: AdminView }
  ]
});

router.beforeEach((to) => {
  const auth = useAuthStore();
  if (!to.meta.public && !auth.isAuthenticated) return '/login';
  if (to.path === '/login' && auth.isAuthenticated) return '/';
});
