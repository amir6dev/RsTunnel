package httpmux

import (
	"bytes"
	"errors"
	"io"
	"net/http"
)

type HTTPConn struct {
	Client     *http.Client
	Mimic      *MimicConfig
	Obfs       *ObfsConfig
	SessionID  string
	ServerURL  string
}

func (hc *HTTPConn) SendFrame(fr *Frame) ([]byte, error) {
	var buf bytes.Buffer

	err := WriteFrame(&buf, fr)
	if err != nil {
		return nil, err
	}

	payload := buf.Bytes()
	payload = ApplyObfuscation(payload, hc.Obfs)
	ApplyDelay(hc.Obfs)

	req, err := http.NewRequest("POST", hc.ServerURL, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}

	ApplyMimicHeaders(req, hc.Mimic, hc.SessionID)

	resp, err := hc.Client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	return io.ReadAll(resp.Body)
}
