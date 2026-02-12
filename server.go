package httpmux

import (
	"bytes"
	"crypto/rand"
	"io"
	"net/http"
	"time"
)

type Server struct {
	SessionMgr *SessionManager
	Mimic      *MimicConfig
	Obfs       *ObfsConfig
	PSK        string
}

func NewServer(timeoutSec int, mimic *MimicConfig, obfs *ObfsConfig, psk string) *Server {
	if timeoutSec <= 0 {
		timeoutSec = 15
	}
	return &Server{
		SessionMgr: NewSessionManager(time.Duration(timeoutSec) * time.Second),
		Mimic:      mimic,
		Obfs:       obfs,
		PSK:        psk,
	}
}

func (s *Server) HandleHTTP(w http.ResponseWriter, r *http.Request) {
	sessionID := extractSessionID(r)

	// set cookie if missing
	if _, err := r.Cookie("SESSION"); err != nil {
		http.SetCookie(w, &http.Cookie{
			Name:  "SESSION",
			Value: sessionID,
			Path:  "/",
		})
	}

	sess := s.SessionMgr.GetOrCreate(sessionID)

	// Bind one pending inbound connection to this session (MVP)
	select {
	case pc := <-globalPending:
		// register server-side link
		serverLinksMu.Lock()
		serverLinks[pc.streamID] = &tcpLink{c: pc.conn}
		serverLinksMu.Unlock()

		// send FrameOpen (tell client to dial target)
		select {
		case sess.Outgoing <- &Frame{
			StreamID: pc.streamID,
			Type:     FrameOpen,
			Length:   uint32(len(pc.target)),
			Payload:  []byte(pc.target),
		}:
		default:
		}
	default:
	}

	// read request body
	reqBody, _ := io.ReadAll(r.Body)
	_ = r.Body.Close()

	// Deobfs -> Decrypt
	reqBody = StripObfuscation(reqBody, s.Obfs)
	plain, err := DecryptPSK(reqBody, s.PSK)
	if err != nil {
		// invalid payload; respond empty
		_, _ = w.Write([]byte{})
		return
	}

	// incoming frames
	reader := bytes.NewReader(plain)
	for {
		fr, err := ReadFrame(reader)
		if err != nil {
			break
		}
		s.handleFrame(sess, fr)
	}

	// outgoing frames (drain)
	var out bytes.Buffer
	max := 256
	for i := 0; i < max; i++ {
		select {
		case fr := <-sess.Outgoing:
			_ = WriteFrame(&out, fr)
		default:
			i = max
		}
	}

	// Encrypt -> Obfs
	enc, err := EncryptPSK(out.Bytes(), s.PSK)
	if err != nil {
		_, _ = w.Write([]byte{})
		return
	}
	resp := ApplyObfuscation(enc, s.Obfs)
	ApplyDelay(s.Obfs)
	_, _ = w.Write(resp)
}

func (s *Server) handleFrame(sess *Session, fr *Frame) {
	switch fr.Type {
	case FramePing:
		select {
		case sess.Outgoing <- &Frame{StreamID: 0, Type: FramePong}:
		default:
		}

	case FrameData:
		// write to inbound socket
		serverLinksMu.Lock()
		link := serverLinks[fr.StreamID]
		serverLinksMu.Unlock()
		if link != nil {
			_, _ = link.c.Write(fr.Payload)
		}

	case FrameClose:
		serverLinksMu.Lock()
		link := serverLinks[fr.StreamID]
		delete(serverLinks, fr.StreamID)
		serverLinksMu.Unlock()
		if link != nil {
			_ = link.c.Close()
		}
	}
}

func extractSessionID(r *http.Request) string {
	cookie, err := r.Cookie("SESSION")
	if err != nil || cookie.Value == "" {
		return "sess-" + RandString(12)
	}
	return cookie.Value
}

func RandString(n int) string {
	const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, n)
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = chars[int(b[i])%len(chars)]
	}
	return string(b)
}
