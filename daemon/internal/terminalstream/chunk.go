package terminalstream

// Chunk is an ordered PTY output fragment in a loop-local stream.
// Seq starts at 1 and increases monotonically for each emitted chunk.
type Chunk struct {
	Seq  uint64
	Data []byte
}
