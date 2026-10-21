/*
 * This file is part of EasyRPG Player.
 *
 * EasyRPG Player is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * EasyRPG Player is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with EasyRPG Player. If not, see <http://www.gnu.org/licenses/>.
 */

#ifdef _WIN32
#include "midiout_device_win32.h"
#include "output.h"

static std::string get_error_str(MMRESULT res) {
	char errMsg[120];
	midiOutGetErrorTextA(res, errMsg, 120);
	return std::string(errMsg);
}

Win32MidiOutDevice::Win32MidiOutDevice(std::string& status_message) {
	// TODO: Windows MIDI Mapper was removed in Windows 8.
	// This means it's impossible to change the default ("0") MIDI device
	// without third party software. We should allow specifying the MIDI device
	// ID in a config file.
	unsigned int device_id = 0;

	MMRESULT err = midiOutOpen(&midi_out, device_id, 0, 0, CALLBACK_NULL);
	if (err != MMSYSERR_NOERROR) {
		status_message = fmt::format("Win32 midiOutOpen {} failed: ({}) {}", 0, err, get_error_str(err));
		midi_out = nullptr;
		return;
	}
}

Win32MidiOutDevice::~Win32MidiOutDevice() {
	if (midi_out) {
		midiOutReset(midi_out);
		for (auto& message : pending) {
			if (message->prepared) midiOutUnprepareHeader(midi_out, &message->header, sizeof(MIDIHDR));
		}
		pending.clear();
		midiOutClose(midi_out);
		midi_out = nullptr;
	}
}

void Win32MidiOutDevice::SendMidiMessage(uint32_t message) {
	if (pending.empty()) {
		midiOutShortMsg(midi_out, message);
		return;
	}
	auto item = std::make_unique<PendingMessage>();
	item->short_message = message;
	pending.push_back(std::move(item));
	FlushOutput();
}

void Win32MidiOutDevice::SendSysExMessage(const uint8_t* data, size_t size) {
	if (size == 0) return;
	auto item = std::make_unique<PendingMessage>();
	item->data.assign(data, data + size);
	pending.push_back(std::move(item));
	FlushOutput();
}

bool Win32MidiOutDevice::FlushOutput() {
	while (!pending.empty()) {
		auto& item = *pending.front();
		if (item.data.empty()) {
			midiOutShortMsg(midi_out, item.short_message);
		} else {
			if (!item.prepared) {
				item.header.lpData = reinterpret_cast<LPSTR>(item.data.data());
				item.header.dwBufferLength = static_cast<DWORD>(item.data.size());
				auto result = midiOutPrepareHeader(midi_out, &item.header, sizeof(MIDIHDR));
				if (result != MMSYSERR_NOERROR) {
					Output::Debug("Win32 midiOutPrepareHeader failed: ({}) {}", result, get_error_str(result));
					pending.pop_front();
					continue;
				}
				item.prepared = true;
				result = midiOutLongMsg(midi_out, &item.header, sizeof(MIDIHDR));
				if (result != MMSYSERR_NOERROR) {
					Output::Debug("Win32 midiOutLongMsg failed: ({}) {}", result, get_error_str(result));
				}
			}
			const auto result = midiOutUnprepareHeader(midi_out, &item.header, sizeof(MIDIHDR));
			if (result == MIDIERR_STILLPLAYING) return false;
			if (result != MMSYSERR_NOERROR) {
				Output::Debug("Win32 midiOutUnprepareHeader failed: ({}) {}", result, get_error_str(result));
				return false;
			}
		}
		pending.pop_front();
	}
	return true;
}

std::string Win32MidiOutDevice::GetName() {
	return "Windows MIDI";
}

bool Win32MidiOutDevice::IsInitialized() const {
	return midi_out != nullptr;
}

#endif
