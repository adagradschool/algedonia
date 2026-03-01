package loopmanager

import (
	"log"

	"github.com/algedonia/daemon/internal/terminalstream"
)

type terminalStreamState struct {
	nextSeq     uint64
	history     []terminalstream.Chunk
	historySize int
}

func (m *Manager) broadcastTerminal(loopID string, data []byte) {
	m.mu.Lock()

	stream, ok := m.termStream[loopID]
	if !ok {
		stream = &terminalStreamState{}
		m.termStream[loopID] = stream
	}
	stream.nextSeq++
	chunk := terminalstream.Chunk{
		Seq:  stream.nextSeq,
		Data: append([]byte(nil), data...),
	}
	stream.history = append(stream.history, chunk)
	stream.historySize += len(chunk.Data)
	for stream.historySize > m.replayMax && len(stream.history) > 0 {
		dropped := stream.history[0]
		stream.history = stream.history[1:]
		stream.historySize -= len(dropped.Data)
	}

	subs := m.termSubs[loopID]
	if len(subs) == 0 {
		m.mu.Unlock()
		return
	}
	type terminalSub struct {
		id uint64
		ch chan terminalstream.Chunk
	}
	chans := make([]terminalSub, 0, len(subs))
	for id, ch := range subs {
		chans = append(chans, terminalSub{id: id, ch: ch})
	}
	m.mu.Unlock()

	for _, sub := range chans {
		select {
		case sub.ch <- chunk:
		default:
			// Do not silently drop PTY bytes: that corrupts ANSI state and causes
			// garbled output. Disconnect the slow subscriber so it can reconnect
			// and resync from canonical scrollback.
			log.Printf("terminal subscriber overflow for loop %s (sub=%d), disconnecting", loopID, sub.id)
			m.unsubscribeTerminal(loopID, sub.id)
		}
	}
}

func (m *Manager) unsubscribeTerminal(loopID string, id uint64) {
	m.mu.Lock()
	defer m.mu.Unlock()

	subs, ok := m.termSubs[loopID]
	if !ok {
		return
	}
	ch, ok := subs[id]
	if !ok {
		return
	}
	delete(subs, id)
	close(ch)
	if len(subs) == 0 {
		delete(m.termSubs, loopID)
	}
}

func cloneChunk(chunk terminalstream.Chunk) terminalstream.Chunk {
	cloned := terminalstream.Chunk{
		Seq:  chunk.Seq,
		Data: make([]byte, len(chunk.Data)),
	}
	copy(cloned.Data, chunk.Data)
	return cloned
}

// SubscribeTerminal streams ordered PTY output for a loop to a dedicated subscriber.
// If fromSeq > 0, replay includes buffered chunks with Seq >= fromSeq.
func (m *Manager) SubscribeTerminal(loopID string, fromSeq uint64) ([]terminalstream.Chunk, <-chan terminalstream.Chunk, func()) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, ok := m.termSubs[loopID]; !ok {
		m.termSubs[loopID] = make(map[uint64]chan terminalstream.Chunk)
	}
	id := m.nextSubID
	m.nextSubID++

	ch := make(chan terminalstream.Chunk, 128)
	m.termSubs[loopID][id] = ch

	replay := make([]terminalstream.Chunk, 0)
	if fromSeq > 0 {
		if stream := m.termStream[loopID]; stream != nil {
			for _, item := range stream.history {
				if item.Seq >= fromSeq {
					replay = append(replay, cloneChunk(item))
				}
			}
		}
	}

	return replay, ch, func() {
		m.unsubscribeTerminal(loopID, id)
	}
}
