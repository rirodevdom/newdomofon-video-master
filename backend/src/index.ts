import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';
import rateLimit from 'express-rate-limit';
import { config } from './config.js';
import { pool } from './db.js';
import { authRouter } from './routes/auth.js';
import { usersRouter } from './routes/users.js';
import { dvrServersRouter } from './routes/dvrServers.js';
import { cameraGroupsRouter } from './routes/cameraGroups.js';
import { camerasRouter } from './routes/cameras.js';
import { favoritesRouter } from './routes/favorites.js';
import { playerPublicArchiveRouter, playerRouter } from './routes/player.js';
import { managedAdminPlayerRouter } from './routes/managedAdminPlayer.js';
import { mediaRouter } from './routes/media.js';
import { auditRouter } from './routes/audit.js';
import { eventsRouter, internalEventsRouter } from './routes/events.js';
import { onvifRouter } from './routes/onvif.js';
import { errorHandler } from './middleware/errorHandler.js';
import { diskProtectionMiddleware, getMasterDiskState } from './middleware/diskProtection.js';
import { cleanupExpiredPlaybackTokens } from './services/tokenCleanup.js';
import { playbackTokensRouter } from './routes/playbackTokens.js';
import { playerCompatRouter } from './routes/playerCompat.js';
import { internalOnvifEventsRouter } from './routes/internalOnvifEvents.js';
import { globalPlaybackTokensRouter } from './routes/globalPlaybackTokens.js';
import { mediaGlobalPublicTokenRouter } from './routes/mediaGlobalPublicToken.js';
import { emptyCameraEventsGuardRouter } from './routes/emptyCameraEventsGuard.js';
import { nodeAgentRouter } from './routes/nodeAgent.js';
import { devicesRouter } from './routes/devices.js';
import { dashboardRouter } from './routes/dashboard.js';
import { tokensRouter } from './routes/tokens.js';
import { managedCameraTokensRouter } from './routes/managedCameraTokens.js';
import { smartYardLinksRouter } from './routes/smartyardLinks.js';
import { internalSmartYardRouter } from './routes/internalSmartYard.js';
import { internalRtspRouter } from './routes/internalRtsp.js';

const app = express();

app.disable('x-powered-by');
if (config.trustProxy) app.set('trust proxy', 1);
app.use(helmet({ crossOriginResourcePolicy: false }));
app.use(cors({ origin: config.corsOrigin, credentials: true }));
app.use(diskProtectionMiddleware);
app.use(express.json({ limit: '1mb' }));
app.use('/api', emptyCameraEventsGuardRouter);
app.use('/api/playback-tokens', playbackTokensRouter);
app.use('/api/media', mediaRouter);
app.use('/api/public-playback-tokens', globalPlaybackTokensRouter);
app.use('/api/public-media', mediaGlobalPublicTokenRouter);
app.use(morgan('combined'));
app.use(rateLimit({ windowMs: 60_000, limit: 600, standardHeaders: 'draft-7', legacyHeaders: false }));

app.get('/api/health', (_req, res) => {
  const disk = getMasterDiskState();
  const degraded = disk.state === 'critical';
  res.json({
    ok: !degraded,
    degraded,
    service: 'backend',
    disk
  });
});

// Internal SmartYard resolver validates a public camera link against the
// media_secret of the camera's assigned node and never exposes that secret.
app.use('/api/internal/smartyard', internalSmartYardRouter);
// MediaMTX calls these loopback-only endpoints for RTSP auth and on-demand
// source resolution. A generated shared secret is required on every request.
app.use('/api/internal/rtsp', internalRtspRouter);

// The explicit 410 event-ingest routes must be mounted before legacy internal
// helpers so master can never persist camera event payloads again.
app.use('/api/internal', internalEventsRouter);
app.use('/api/internal', internalOnvifEventsRouter);
app.use('/api/node-agent', nodeAgentRouter);
app.use('/api/auth', authRouter);
app.use('/api/users', usersRouter);
app.use('/api/dvr-servers', dvrServersRouter);
app.use('/api/devices', devicesRouter);
app.use('/api/dashboard', dashboardRouter);
// Managed token routes are mounted first so camera links require an explicitly
// selected reusable token instead of minting an ad-hoc token on every click.
app.use('/api/tokens', managedCameraTokensRouter);
app.use('/api/tokens/smartyard-links', smartYardLinksRouter);
app.use('/api/tokens', tokensRouter);
app.use('/api/camera-groups', cameraGroupsRouter);
app.use('/api/cameras', camerasRouter);
// Public HLS archive proxy must be mounted before any broad /api router
// that installs requireAuth, especially eventsRouter mounted at /api.
app.use('/api/player', playerPublicArchiveRouter);
app.use('/api', eventsRouter);
app.use('/api/favorites', favoritesRouter);
// Admin live and node-archive URLs must use an assigned managed token. This
// router is mounted before the legacy authenticated player router, which still
// handles device archive preparation, ranges, export and compatibility paths.
app.use('/api/player', managedAdminPlayerRouter);
app.use('/api/player', playerRouter);
app.use('/api/player', playerCompatRouter);

app.use('/api/audit', auditRouter);
app.use('/api/onvif', onvifRouter);

app.use(errorHandler);

cleanupExpiredPlaybackTokens().catch(console.error);
setInterval(() => cleanupExpiredPlaybackTokens().catch(console.error), 60 * 60 * 1000);

const server = app.listen(config.port, () => {
  console.log(`Backend listening on ${config.port}`);
});

async function shutdown(signal: string) {
  console.log(`Received ${signal}`);
  server.close(async () => {
    await pool.end();
    process.exit(0);
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
