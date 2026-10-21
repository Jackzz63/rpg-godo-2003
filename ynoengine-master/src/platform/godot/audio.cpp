#ifdef SUPPORT_AUDIO

#include "audio.h"
#include "audio_decoder.h"
#include <limits>

GodotAudio::GodotAudio(const Game_ConfigAudio& cfg)
	: GenericAudio(cfg)
{
	SetFormat(SAMPLE_RATE, AudioDecoder::Format::S16, 2); // godot AudioStreamGenerator default
}

std::vector<int16_t> GodotAudio::PullFrames(int frame_count) {
	std::vector<int16_t> out;
	PullFrames(frame_count, out);
	return out;
}

void GodotAudio::PullFrames(int frame_count, std::vector<int16_t>& out) {
	constexpr int bytes_per_frame = 2 * sizeof(int16_t);
	if (frame_count <= 0 || frame_count > std::numeric_limits<int>::max() / bytes_per_frame) {
		out.clear();
		return;
	}
	out.resize(static_cast<size_t>(frame_count) * 2);
	// GenericAudio writes every byte, including silence. Keep the existing
	// synchronization contract; no Godot calls occur under this mixer lock.
	std::lock_guard<std::mutex> lock(mutex_);
	Decode(reinterpret_cast<uint8_t*>(out.data()), frame_count * bytes_per_frame);
}

void GodotAudio::LockMutex() const {
	mutex_.lock();
}

void GodotAudio::UnlockMutex() const {
	mutex_.unlock();
}

#endif // SUPPORT_AUDIO
