# To do

Ideas that are agreed on but not built, and things nobody has tried yet.

## Ideas

- **The app should find its tools by itself.** Today it expects `herdr-voice` in `~/.local/bin` and
  `hc` in one of three folders. It should ask the login shell for its PATH instead.
- **Streaming transcription.** The phone page has a simple version (the recording so far is
  transcribed about once a second). Open: the same in the desktop app, and true streaming. FluidAudio
  offers `SlidingWindowAsrManager` (overlapping windows, probably with the Parakeet model the app
  already has) and separate streaming models: Parakeet Unified 0.6B streaming, Nemotron Streaming
  0.6B and Parakeet EOU 120M. None of these has been tried here.
- **Desktop app: switching sessions while one is working drops the reply.** The app keeps one
  "working" flag for all sessions, so talking to a second session is sent as a steer and its answer
  is discarded. The phone page does not have this problem.
- **Send now in the desktop app.** The phone page has the button; the app needs a gesture for it.
  Agent programs other than Claude Code are refused because their key for this is not known.
- **Narration verbosity.** A way to choose how much an agent narrates. Not designed; today it is the
  agent's own judgement.
- **Learned word list.** Agents record mishearings with a small command next to `herdr-speak`
  (`herdr-heard "<heard>" "<meant>"`); the server corrects those words in every later transcript.
  Whole words, case-insensitive, a plain text file. Risk to design around: one wrong entry damages
  every later transcript.
- **Vocabulary boosting.** FluidAudio's custom-vocabulary feature could use the same word list.
- **Ten-year certificate authority** with automatic renewal of the server certificate (iPhones cap a
  server certificate at 825 days).
- **One settings file.** `port`, `voice`, `mode` and `compact` are small files in the state folder;
  `allow` and `instruction` are in `config.json`. They could live in one place.
- **Smaller audio for the phone.** Replies reach the phone as uncompressed WAV.
- **Lines in `app.log` overwrite each other.** The app and the server it starts write to the log
  through separate file handles, and the server's is not in append mode.
- **A stop can leave a message behind.** A stop that lands before the agent starts can leave the
  cancelled message in its input box, where it merges with the next one. Seen once, not reproduced.

## Not tried yet

- Every button in the Setup window, and the Connect a Phone window on a phone set up from nothing.
- Two sessions in use at once on the phone page.
- The Send now button in a real browser (its server side is tested).
- Announcements moving to the other devices when the device you last talked through goes away.
- The hold-Option+Command guard against everyday Option+Command shortcuts.
- An Intel Mac, an Android phone, and versions of `hc` other than 0.1.21.
- The licences of the Parakeet and Kokoro models have not been read; the app downloads the models, it
  does not ship them.
