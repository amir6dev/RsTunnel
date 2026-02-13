package httpmux

import (
	"bytes"
	"encoding/hex"
	"io"
	"net/http"
	"sync"
	"time"
)

type Server struct {
	SessionMgr   *SessionManager
	Mimic        *MimicConfig
	Obfs         *ObfsConfig
	PSK          string
	activeSessMu sync.RWMutex
	activeSess   *Session
}

func NewServer(timeoutSec int, mimic *MimicConfig, obfs *ObfsConfig, psk string) *Server {
	if timeoutSec <= 0 {
		timeoutSec = 15
	}
	return &Server{SessionMgr: NewSessionManager(time.Duration(timeoutSec) * time.Second), Mimic: mimic, Obfs: obfs, PSK: psk}
}

func (s *Server) setActiveSession(sess *Session) {
	s.activeSessMu.Lock()
	s.activeSess = sess
	s.activeSessMu.Unlock()
}
func (s *Server) getActiveSession() *Session {
	s.activeSessMu.RLock()
	defer s.activeSessMu.RUnlock()
	return s.activeSess
}

func (s *Server) HandleHTTP(w http.ResponseWriter, r *http.Request) {
	if s.Mimic != nil && s.Mimic.FakePath != "" && r.URL.Path != s.Mimic.FakePath {
		s.writeDecoyHTTP200(w, r)
		return
	}

	sessionID := extractSessionID(r)
	if s.Mimic != nil && s.Mimic.SessionCookie {
		// rotate cookie every response to mimic Dagger behavior
		http.SetCookie(w, &http.Cookie{Name: "session", Value: extractSessionID(r), Path: "/", HttpOnly: true, SameSite: http.SameSiteLaxMode})
	}
	sess := s.SessionMgr.GetOrCreate(sessionID)
	s.setActiveSession(sess)

	reqBody, _ := io.ReadAll(r.Body)
	_ = r.Body.Close()
	if len(reqBody) == 0 {
		s.writeDecoyHTTP200(w, r)
		return
	}

	reqBody = StripObfuscation(reqBody, s.Obfs)
	plain, err := DecryptPSK(reqBody, s.PSK)
	if err != nil {
		s.writeDecoyHTTP200(w, r)
		return
	}
	reader := bytes.NewReader(plain)
	for {
		fr, err := ReadFrame(reader)
		if err != nil {
			break
		}
		s.handleFrame(sess, fr)
	}

	var out bytes.Buffer
	select {
	case fr := <-sess.Outgoing:
		_ = WriteFrame(&out, fr)
	case <-time.After(20 * time.Second):
	}
	if out.Len() > 0 {
		for i := 0; i < 128; i++ {
			select {
			case fr := <-sess.Outgoing:
				_ = WriteFrame(&out, fr)
			default:
				i = 128
			}
		}
	}

	enc, _ := EncryptPSK(out.Bytes(), s.PSK)
	resp := ApplyObfuscation(enc, s.Obfs)
	ApplyDelay(s.Obfs)
	w.Header().Set("Content-Type", "application/octet-stream")
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
		serverLinksMu.Lock()
		link := serverLinks[fr.StreamID]
		serverLinksMu.Unlock()
		if link != nil {
			_, _ = link.c.Write(fr.Payload)
			return
		}
		serverUDPLinksMu.Lock()
		ul := serverUDPLinks[fr.StreamID]
		serverUDPLinksMu.Unlock()
		if ul != nil && ul.ln != nil && ul.peer != nil {
			_, _ = ul.ln.WriteToUDP(fr.Payload, ul.peer)
		}
	case FrameClose:
		serverLinksMu.Lock()
		link := serverLinks[fr.StreamID]
		delete(serverLinks, fr.StreamID)
		serverLinksMu.Unlock()
		if link != nil {
			_ = link.c.Close()
			return
		}
		serverUDPLinksMu.Lock()
		ul := serverUDPLinks[fr.StreamID]
		if ul != nil && ul.ln != nil && ul.peer != nil {
			delete(serverUDPKeyToID, ul.ln.LocalAddr().String()+"|"+ul.peer.String())
		}
		delete(serverUDPLinks, fr.StreamID)
		serverUDPLinksMu.Unlock()
	}
}

func extractSessionID(r *http.Request) string {
	if c, _ := r.Cookie("session"); c != nil && c.Value != "" {
		return c.Value
	}
	b := []byte(RandString(32))
	enc := make([]byte, hex.EncodedLen(len(b)))
	hex.Encode(enc, b)
	if len(enc) >= 32 {
		return string(enc[:32])
	}
	return "sess-" + RandString(12)
}

func (s *Server) writeDecoyHTTP200(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Server", "nginx/1.18.0")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "private, max-age=0")
	w.Header().Set("X-Frame-Options", "SAMEORIGIN")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if s.Mimic != nil && s.Mimic.SessionCookie {
		http.SetCookie(w, &http.Cookie{Name: "session", Value: extractSessionID(r), Path: "/", HttpOnly: true, SameSite: http.SameSiteLaxMode})
	}
	w.WriteHeader(http.StatusOK)
}
