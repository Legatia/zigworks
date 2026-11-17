// headsound's Apple layer: decoding any file Core Audio reads, the microphone
// through an AudioQueue, and the microphone permission.
#pragma once

enum { HSND_OK = 0, HSND_UNSUPPORTED = 1, HSND_FAIL = 2, HSND_PERMISSION = 3, HSND_NO_HOST = 4, HSND_NO_INPUT = 5, HSND_UNANSWERED = 6 };

// Decodes `path` to interleaved float samples (free with hsnd_free).
int hsnd_decode(const char *path, float **out, long long *frames, int *rate, int *channels, char *codec, int codec_len);
void hsnd_free(void *p);

// Name of the app this process runs under (Terminal, iTerm, ...); 0 if none.
int hsnd_host_app(char *buf, int len);

// Microphone permission for the host app; asks (once) if it was never decided.
// HSND_UNANSWERED: asked, and nobody answered within two minutes.
int hsnd_mic_access(void);

// Records mono float samples at `rate` Hz and hands them to `sink` in chunks
// of about 100 ms until `sink` returns nonzero or `max_ms` passes.
typedef int (*hsnd_sink)(void *ctx, const float *samples, int n);
int hsnd_listen(double rate, hsnd_sink sink, void *ctx, int max_ms);

// Classifies sounds in mono `samples` with Apple's built-in classifier
// (SoundAnalysis): for each window of `window_s` seconds (half overlapping),
// every class with confidence >= `floor` goes to `sink`.
typedef void (*hsnd_class_sink)(void *ctx, double start, double duration, const char *label, double confidence);
int hsnd_classify(const float *samples, long long frames, double rate, double window_s, double floor, hsnd_class_sink sink, void *ctx);
// Every class the classifier knows, one call each.
int hsnd_class_names(void (*sink)(void *ctx, const char *label), void *ctx);

// Speech recognition permission for the host app; asks (once, waiting up
// to two minutes) if it was never decided.
int hsnd_speech_access(void);

// Transcribes mono `samples` on this Mac (never on a server): each word
// with its start and length in seconds and the recogniser's confidence.
// `locale` NULL or "" means the user's language; the one used is written to
// `used` (`used_len` bytes). HSND_UNSUPPORTED: no on-device recognition for
// that language. No speech at all is HSND_OK with no words.
// `space_before`: 0 where the language writes the word onto the one before.
typedef void (*hsnd_word_sink)(void *ctx, const char *text, double start, double duration, double confidence, int space_before);
int hsnd_transcribe(const float *samples, long long frames, double rate, const char *locale, char *used, int used_len,
                    hsnd_word_sink sink, void *ctx);
