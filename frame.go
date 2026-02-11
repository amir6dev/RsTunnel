package httpmux

import (
	"encoding/binary"
	"errors"
	"io"
)

const (
	FrameData  = 0x01
	FramePing  = 0x02
	FramePong  = 0x03
	FrameClose = 0x04
)

type Frame struct {
	StreamID uint32
	Type     byte
	Length   uint32
	Payload  []byte
}

func WriteFrame(w io.Writer, fr *Frame) error {
	header := make([]byte, 9)
	binary.BigEndian.PutUint32(header[0:4], fr.StreamID)
	header[4] = fr.Type
	binary.BigEndian.PutUint32(header[5:9], fr.Length)

	_, err := w.Write(header)
	if err != nil {
		return err
	}

	if fr.Length > 0 && fr.Payload != nil {
		_, err = w.Write(fr.Payload)
	}
	return err
}

func ReadFrame(r io.Reader) (*Frame, error) {
	header := make([]byte, 9)
	_, err := io.ReadFull(r, header)
	if err != nil {
		return nil, err
	}

	streamID := binary.BigEndian.Uint32(header[0:4])
	frameType := header[4]
	length := binary.BigEndian.Uint32(header[5:9])

	payload := make([]byte, length)
	if length > 0 {
		_, err = io.ReadFull(r, payload)
		if err != nil {
			return nil, err
		}
	}

	return &Frame{
		StreamID: streamID,
		Type:     frameType,
		Length:   length,
		Payload:  payload,
	}, nil
}
