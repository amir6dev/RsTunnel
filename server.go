package httpmux

import (
	"io"
	"net/http"
)

type Server struct {
	SessionMgr *SessionManager
	Mimic      *MimicConfig
	Obfs       *ObfsConfig
}

func NewServer(timeout int, mimic *MimicConfig, obfs *ObfsConfig) *Server {
	return &Server{
		SessionMgr: NewSessionManager(time.Duration(timeout) * time.Second),
		Mimic:      mimic,
		Obfs:       obfs,
	}
}

func (s *Server) HandleHTTP(w http.ResponseWriter, r *http.Request) {
	sessionID := extractSessionID(r)
	sess := s.SessionMgr.Get(sessionID)
	if sess == nil {
		sess = s.SessionMgr.Create(sessionID)
	}

	data, _ := io.ReadAll(r.Body)
	r.Body.Close()

	data = stripObfs(data, s.Obfs)

	reader := bytes.NewReader(data)
	for {
		fr, err := ReadFrame(reader)
		if err != nil {
			break
		}

		s.handleFrame(sess, fr)
	}

	out := s.collectOutgoingFrames(sess)
	w.Write(out)
}

func (s *Server) handleFrame(sess *Session, fr *Frame) {
	sess.Mutex.Lock()
	defer sess.Mutex.Unlock()

	str := sess.Streams[fr.StreamID]
	if str == nil {
		str = NewStream(fr.StreamID, nil)
		sess.Streams[fr.StreamID] = str
	}

	switch fr.Type {
	case FrameData:
		go forwardTCP(str, fr.Payload)
	case FrameClose:
		str.shutdown()
	}
}

func extractSessionID(r *http.Request) string {
	cookie, err := r.Cookie("SESSION")
	if err != nil {
		return "sess-" + RandString(12)
	}
	return cookie.Value
}
