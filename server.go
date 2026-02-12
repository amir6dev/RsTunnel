package httpmux

import (
	"bytes"
	"io"
	"net/http"
	"time"
)

type Server struct {
	SessionMgr *SessionManager
	Obfs       *ObfsConfig
}

func NewServer(timeoutSec int, obfs *ObfsConfig) *Server {
	return &Server{
		SessionMgr: NewSessionManager(time.Duration(timeoutSec) * time.Second),
		Obfs:       obfs,
	}
}

func (s *Server) HandleHTTP(w http.ResponseWriter, r *http.Request) {
	sessionID := extractSessionID(r)
	// اگر کوکی نبود، ستش کن که بعداً ثابت بمونه
	_, err := r.Cookie("SESSION")
	if err != nil {
		http.SetCookie(w, &http.Cookie{
			Name:  "SESSION",
			Value: sessionID,
			Path:  "/",
		})
	}

	sess := s.SessionMgr.GetOrCreate(sessionID)

	reqBody, _ := io.ReadAll(r.Body)
	_ = r.Body.Close()
	reqBody = StripObfuscation(reqBody, s.Obfs)

	// incoming frames
	reader := bytes.NewReader(reqBody)
	for {
		fr, err := ReadFrame(reader)
		if err != nil {
			break
		}
		s.handleFrame(sess, fr)
	}

	// outgoing frames (drain)
	var out bytes.Buffer
	// محدود کن که response خیلی بزرگ نشه
	max := 128
	for i := 0; i < max; i++ {
		select {
		case fr := <-sess.Outgoing:
			_ = WriteFrame(&out, fr)
		default:
			i = max // break
		}
	}

	resp := ApplyObfuscation(out.Bytes(), s.Obfs)
	ApplyDelay(s.Obfs)
	_, _ = w.Write(resp)
}

func (s *Server) handleFrame(sess *Session, fr *Frame) {
	// اینجا فعلاً فقط برای تست: Echo
	// بعداً همینجا forwardTCP واقعی رو می‌چسبونیم (مرحله بعد)
	switch fr.Type {
	case FramePing:
		select {
		case sess.Outgoing <- &Frame{StreamID: 0, Type: FramePong}:
		default:
		}

	case FrameData:
		// echo back
		select {
		case sess.Outgoing <- &Frame{
			StreamID: fr.StreamID,
			Type:     FrameData,
			Length:   uint32(len(fr.Payload)),
			Payload:  fr.Payload,
		}:
		default:
		}

	case FrameClose:
		select {
		case sess.Outgoing <- &Frame{StreamID: fr.StreamID, Type: FrameClose}:
		default:
		}
	}
}

func extractSessionID(r *http.Request) string {
	cookie, err := r.Cookie("SESSION")
	if err != nil {
		return "sess-" + RandString(12)
	}
	return cookie.Value
}
