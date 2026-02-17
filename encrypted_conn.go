package httpmux

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"io"
	"math/big"
	"net"
	"sync"
	"time"
)

// ═══════════════════════════════════════════════════════════════
// EncryptedConn — per-packet AES-256-GCM encryption wrapper
//
// This is a drop-in net.Conn that encrypts EVERYTHING on the wire.
// All smux control frames, data, keepalives — all encrypted.
//
// Wire format:
//   [4B big-endian packet_length][12B nonce][ciphertext + 16B GCM tag]
//
// Padding (PicoTun):
//   Applied BEFORE encryption so DPI cannot see real data sizes.
//   Padded plaintext format: [2B original_length][original_data][random_padding]
//   This matches PicoTun's addPadding/removePadding approach.
// ═══════════════════════════════════════════════════════════════

type EncryptedConn struct {
	conn net.Conn
	gcm  cipher.AEAD
	obfs *ObfsConfig

	readMu  sync.Mutex
	writeMu sync.Mutex
	readBuf []byte // leftover from previous Read
}

// NewEncryptedConn wraps conn with AES-256-GCM encryption.
// PSK → SHA-256 → AES-256-GCM key. Empty PSK = passthrough (length-framed only).
func NewEncryptedConn(conn net.Conn, psk string, obfs *ObfsConfig) (*EncryptedConn, error) {
	ec := &EncryptedConn{conn: conn, obfs: obfs}

	if psk == "" {
		return ec, nil // passthrough
	}

	hash := sha256.Sum256([]byte(psk))
	block, err := aes.NewCipher(hash[:])
	if err != nil {
		return nil, fmt.Errorf("aes: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("gcm: %w", err)
	}
	ec.gcm = gcm
	return ec, nil
}

// ──────────────────── Write ────────────────────

func (c *EncryptedConn) Write(data []byte) (int, error) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	payload := data

	// ① Padding BEFORE encryption (PicoTun: sizes are hidden)
	if c.obfs != nil && c.obfs.Enabled {
		payload = addPadding(data, c.obfs)
	}

	// ② Encrypt
	if c.gcm != nil {
		nonce := make([]byte, c.gcm.NonceSize()) // 12 bytes
		if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
			return 0, fmt.Errorf("nonce: %w", err)
		}
		ciphertext := c.gcm.Seal(nil, nonce, payload, nil)

		pktLen := len(nonce) + len(ciphertext)
		buf := make([]byte, 4+pktLen)
		binary.BigEndian.PutUint32(buf[:4], uint32(pktLen))
		copy(buf[4:], nonce)
		copy(buf[4+len(nonce):], ciphertext)

		if _, err := c.conn.Write(buf); err != nil {
			return 0, err
		}
	} else {
		// No encryption — still length-framed for consistency
		buf := make([]byte, 4+len(payload))
		binary.BigEndian.PutUint32(buf[:4], uint32(len(payload)))
		copy(buf[4:], payload)

		if _, err := c.conn.Write(buf); err != nil {
			return 0, err
		}
	}

	// ③ Traffic timing jitter — ONLY for large data packets (>128 bytes)
	//    NEVER delay smux keepalive/control frames (they're small)
	//    This prevents delay from killing smux session keepalive
	if c.obfs != nil && c.obfs.Enabled && c.obfs.MaxDelayMS > 0 && len(data) > 128 {
		obfsDelay(c.obfs)
	}

	return len(data), nil
}

// ──────────────────── Read ────────────────────

func (c *EncryptedConn) Read(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()

	// Return leftover from previous read first (important for smux)
	if len(c.readBuf) > 0 {
		n := copy(p, c.readBuf)
		c.readBuf = c.readBuf[n:]
		return n, nil
	}

	// Read 4-byte length header
	header := make([]byte, 4)
	if _, err := io.ReadFull(c.conn, header); err != nil {
		return 0, err
	}
	pktLen := binary.BigEndian.Uint32(header)
	if pktLen == 0 || pktLen > 16<<20 { // 16MB sanity
		return 0, fmt.Errorf("invalid packet length: %d", pktLen)
	}

	// Read encrypted payload
	pkt := make([]byte, pktLen)
	if _, err := io.ReadFull(c.conn, pkt); err != nil {
		return 0, err
	}

	// Decrypt
	var plaintext []byte
	if c.gcm != nil {
		ns := c.gcm.NonceSize()
		if int(pktLen) < ns {
			return 0, fmt.Errorf("packet too short")
		}
		var err error
		plaintext, err = c.gcm.Open(nil, pkt[:ns], pkt[ns:], nil)
		if err != nil {
			return 0, fmt.Errorf("decrypt: %w", err)
		}
	} else {
		plaintext = pkt
	}

	// Remove padding
	if c.obfs != nil && c.obfs.Enabled {
		plaintext = removePadding(plaintext)
		if plaintext == nil {
			return 0, fmt.Errorf("invalid padding")
		}
	}

	n := copy(p, plaintext)
	if n < len(plaintext) {
		// Store remaining for next Read call
		c.readBuf = make([]byte, len(plaintext)-n)
		copy(c.readBuf, plaintext[n:])
	}
	return n, nil
}

// ──────────────────── Padding (PicoTun) ────────────────────
// Format: [2B original_length][original_data][random_padding]
// This is applied BEFORE encryption, so encrypted packet sizes don't
// reveal real data sizes to DPI.

func addPadding(data []byte, obfs *ObfsConfig) []byte {
	padLen := obfs.MinPadding
	diff := obfs.MaxPadding - obfs.MinPadding
	if diff > 0 {
		padLen += secureRandInt(diff)
	}
	out := make([]byte, 2+len(data)+padLen)
	binary.BigEndian.PutUint16(out[:2], uint16(len(data)))
	copy(out[2:], data)
	if padLen > 0 {
		rand.Read(out[2+len(data):])
	}
	return out
}

func removePadding(data []byte) []byte {
	if len(data) < 2 {
		return nil
	}
	origLen := binary.BigEndian.Uint16(data[:2])
	if int(origLen)+2 > len(data) {
		return nil
	}
	return data[2 : 2+origLen]
}

// ──────────────────── Traffic timing ────────────────────

func obfsDelay(obfs *ObfsConfig) {
	min := obfs.MinDelayMS
	max := obfs.MaxDelayMS
	if max <= min || max <= 0 {
		return
	}
	d := min + secureRandInt(max-min)
	if d > 0 {
		time.Sleep(time.Duration(d) * time.Millisecond)
	}
}

// ──────────────────── net.Conn interface ────────────────────

func (c *EncryptedConn) Close() error                       { return c.conn.Close() }
func (c *EncryptedConn) LocalAddr() net.Addr                { return c.conn.LocalAddr() }
func (c *EncryptedConn) RemoteAddr() net.Addr               { return c.conn.RemoteAddr() }
func (c *EncryptedConn) SetDeadline(t time.Time) error      { return c.conn.SetDeadline(t) }
func (c *EncryptedConn) SetReadDeadline(t time.Time) error  { return c.conn.SetReadDeadline(t) }
func (c *EncryptedConn) SetWriteDeadline(t time.Time) error { return c.conn.SetWriteDeadline(t) }

var _ net.Conn = (*EncryptedConn)(nil)

// ──────────────────── Crypto-safe random ────────────────────

func secureRandInt(n int) int {
	if n <= 0 {
		return 0
	}
	val, err := rand.Int(rand.Reader, big.NewInt(int64(n)))
	if err != nil {
		return 0
	}
	return int(val.Int64())
}
