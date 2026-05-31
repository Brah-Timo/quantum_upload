/**
 * quantum_upload — Reference Node.js Server
 * ============================================
 *
 * A minimal Express server that receives chunked uploads from the Dart
 * `quantum_upload` package and reassembles them into the original file.
 *
 * It handles every HTTP header sent by the library:
 *   X-Session-Id      → identifies the upload session
 *   X-Chunk-Index     → 0-based position of this chunk
 *   X-Total-Chunks    → total chunks expected
 *   X-Chunk-Checksum  → MD5 hex digest for integrity verification
 *   X-File-Size       → total file size in bytes
 *   Content-Range     → standard byte-range header
 *
 * ## Quick start
 *
 *   npm install express multer busboy md5-file
 *   node server.js
 *
 * The server listens on port 8080 by default.
 */

const express   = require('express');
const multer    = require('multer');
const fs        = require('fs');
const path      = require('path');
const crypto    = require('crypto');
const { promisify } = require('util');

const app    = express();
const PORT   = process.env.PORT || 8080;
const UPLOAD = process.env.UPLOAD_DIR || path.join(__dirname, 'uploads');
const TMP    = path.join(UPLOAD, '.tmp');

// ── Ensure directories exist ──────────────────────────────────────────────────
fs.mkdirSync(UPLOAD, { recursive: true });
fs.mkdirSync(TMP,    { recursive: true });

// ── Multer configuration ──────────────────────────────────────────────────────
// Store each chunk in a temp folder named after the session ID.
const storage = multer.diskStorage({
  destination(req, file, cb) {
    const sessionDir = path.join(TMP, req.headers['x-session-id'] || 'unknown');
    fs.mkdirSync(sessionDir, { recursive: true });
    cb(null, sessionDir);
  },
  filename(req, file, cb) {
    const idx = parseInt(req.headers['x-chunk-index'] || '0', 10);
    cb(null, `chunk_${String(idx).padStart(6, '0')}`);
  },
});
const upload = multer({ storage });

// ── In-memory session registry ────────────────────────────────────────────────
// Production should use Redis or a DB for multi-instance deployments.
const sessions = new Map(); // sessionId → { totalChunks, received, fileName }

// ═════════════════════════════════════════════════════════════════════════════
// POST /upload
// ═════════════════════════════════════════════════════════════════════════════

app.post('/upload', upload.single('chunk'), async (req, res) => {
  const sessionId   = req.headers['x-session-id'];
  const chunkIndex  = parseInt(req.headers['x-chunk-index'],  10);
  const totalChunks = parseInt(req.headers['x-total-chunks'], 10);
  const checksum    = req.headers['x-chunk-checksum'];
  const fileSize    = parseInt(req.headers['x-file-size'] || '0', 10);

  // ── Validate required headers ──────────────────────────────────────────────
  if (!sessionId || isNaN(chunkIndex) || isNaN(totalChunks)) {
    return res.status(400).json({
      error: 'Missing required headers: X-Session-Id, X-Chunk-Index, X-Total-Chunks',
    });
  }

  if (!req.file) {
    return res.status(400).json({ error: 'No chunk file in request body.' });
  }

  // ── Verify MD5 checksum ────────────────────────────────────────────────────
  if (checksum) {
    const chunkBuffer = fs.readFileSync(req.file.path);
    const computed    = crypto.createHash('md5').update(chunkBuffer).digest('hex');
    if (computed !== checksum) {
      fs.unlinkSync(req.file.path);
      console.error(`[${sessionId}] Checksum mismatch on chunk ${chunkIndex}: `
                    + `expected ${checksum}, got ${computed}`);
      return res.status(422).json({
        error: `Checksum mismatch for chunk ${chunkIndex}`,
        expected: checksum,
        received: computed,
      });
    }
  }

  // ── Register session ───────────────────────────────────────────────────────
  if (!sessions.has(sessionId)) {
    sessions.set(sessionId, {
      totalChunks,
      fileSize,
      received: new Set(),
      uploadedAt: new Date().toISOString(),
    });
    console.log(`[${sessionId}] New session — ${totalChunks} chunks, `
                + `${(fileSize / (1024 * 1024)).toFixed(2)} MiB`);
  }

  const session = sessions.get(sessionId);
  session.received.add(chunkIndex);

  console.log(`[${sessionId}] Chunk ${chunkIndex + 1}/${totalChunks} ✓`);

  // ── All chunks received? → assemble ───────────────────────────────────────
  if (session.received.size === totalChunks) {
    try {
      const outputPath = await _assembleFile(sessionId, totalChunks);
      const stats      = fs.statSync(outputPath);
      sessions.delete(sessionId);

      console.log(`[${sessionId}] Assembly complete → ${outputPath}`);

      return res.status(200).json({
        status    : 'complete',
        sessionId,
        outputPath: path.basename(outputPath),
        sizeBytes : stats.size,
        message   : 'All chunks received and assembled successfully.',
      });
    } catch (err) {
      console.error(`[${sessionId}] Assembly failed:`, err);
      return res.status(500).json({ error: 'Assembly failed.', detail: err.message });
    }
  }

  // ── Not complete yet → acknowledge ────────────────────────────────────────
  return res.status(200).json({
    status      : 'partial',
    sessionId,
    chunkIndex,
    receivedCount: session.received.size,
    totalChunks,
    remaining   : totalChunks - session.received.size,
  });
});

// ═════════════════════════════════════════════════════════════════════════════
// GET /session/:id  — check session status
// ═════════════════════════════════════════════════════════════════════════════

app.get('/session/:id', (req, res) => {
  const session = sessions.get(req.params.id);
  if (!session) {
    return res.status(404).json({ error: 'Session not found.' });
  }
  res.json({
    sessionId    : req.params.id,
    totalChunks  : session.totalChunks,
    receivedCount: session.received.size,
    missing      : Array.from({ length: session.totalChunks }, (_, i) => i)
                       .filter(i => !session.received.has(i)),
  });
});

// ═════════════════════════════════════════════════════════════════════════════
// DELETE /session/:id  — cancel and clean up
// ═════════════════════════════════════════════════════════════════════════════

app.delete('/session/:id', (req, res) => {
  const id = req.params.id;
  const sessionDir = path.join(TMP, id);
  if (fs.existsSync(sessionDir)) {
    fs.rmSync(sessionDir, { recursive: true, force: true });
  }
  sessions.delete(id);
  res.json({ status: 'cancelled', sessionId: id });
});

// ═════════════════════════════════════════════════════════════════════════════
// File assembly
// ═════════════════════════════════════════════════════════════════════════════

async function _assembleFile(sessionId, totalChunks) {
  const sessionDir = path.join(TMP, sessionId);
  const outputPath = path.join(UPLOAD, `${sessionId}.bin`);
  const writeStream = fs.createWriteStream(outputPath);

  for (let i = 0; i < totalChunks; i++) {
    const chunkPath = path.join(sessionDir, `chunk_${String(i).padStart(6, '0')}`);
    await new Promise((resolve, reject) => {
      const readStream = fs.createReadStream(chunkPath);
      readStream.pipe(writeStream, { end: false });
      readStream.on('end', resolve);
      readStream.on('error', reject);
    });
  }

  await new Promise((resolve, reject) => {
    writeStream.end(resolve);
    writeStream.on('error', reject);
  });

  // Clean up temp chunk files
  fs.rmSync(sessionDir, { recursive: true, force: true });
  return outputPath;
}

// ─────────────────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`\n🚀  quantum_upload server running on http://localhost:${PORT}`);
  console.log(`    Upload endpoint  : POST http://localhost:${PORT}/upload`);
  console.log(`    Session status   : GET  http://localhost:${PORT}/session/:id`);
  console.log(`    Cancel session   : DEL  http://localhost:${PORT}/session/:id`);
  console.log(`    Assembled files  : ${UPLOAD}\n`);
});

