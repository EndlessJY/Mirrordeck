package com.genymobile.scrcpy.audio;

import com.genymobile.scrcpy.AndroidVersions;
import com.genymobile.scrcpy.AsyncProcessor;
import com.genymobile.scrcpy.FakeContext;
import com.genymobile.scrcpy.Options;
import com.genymobile.scrcpy.device.Device;
import com.genymobile.scrcpy.device.Streamer;
import com.genymobile.scrcpy.model.Codec;
import com.genymobile.scrcpy.model.CodecOption;
import com.genymobile.scrcpy.model.ConfigurationException;
import com.genymobile.scrcpy.util.CodecUtils;
import com.genymobile.scrcpy.util.IO;
import com.genymobile.scrcpy.util.Ln;
import com.genymobile.scrcpy.util.LogUtils;

import android.annotation.SuppressLint;
import android.annotation.TargetApi;
import android.content.ComponentName;
import android.content.Context;
import android.content.pm.PackageManager;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.Looper;
import android.os.SystemClock;
import android.view.KeyEvent;

import java.io.IOException;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;

public final class AudioEncoder implements AsyncProcessor {

    private static class InputTask {
        private final int index;

        InputTask(int index) {
            this.index = index;
        }
    }

    private static class OutputTask {
        private final int index;
        private final MediaCodec.BufferInfo bufferInfo;

        OutputTask(int index, MediaCodec.BufferInfo bufferInfo) {
            this.index = index;
            this.bufferInfo = bufferInfo;
        }
    }

    private static final int SAMPLE_RATE = AudioConfig.SAMPLE_RATE;
    private static final int CHANNELS = AudioConfig.CHANNELS;
    // LANADB: drain window after pausing media before releasing AudioCapture,
    // preventing a brief audio burst on the phone speaker.
    private static final long PAUSE_DRAIN_DELAY_MS = 180;
    private static final long RECENT_AUDIO_WINDOW_MS = 2000;

    private final AudioCapture capture;
    private final Streamer streamer;
    private final int bitRate;
    private final List<CodecOption> codecOptions;
    private final String encoderName;
    private final int audioUid;
    private final boolean pauseMediaOnRelease;

    private boolean recreatePts;
    private long previousPts;

    // Capacity of 64 is in practice "infinite" (it is limited by the number of available MediaCodec buffers, typically 4).
    // So many pending tasks would lead to an unacceptable delay anyway.
    private final BlockingQueue<InputTask> inputTasks = new ArrayBlockingQueue<>(64);
    private final BlockingQueue<OutputTask> outputTasks = new ArrayBlockingQueue<>(64);

    private Thread thread;
    private HandlerThread mediaCodecThread;

    private Thread inputThread;
    private Thread outputThread;

    private boolean ended;
    // LANADB: server-side audio capture toggle (false while muted).
    private boolean captureEnabled;
    private boolean sessionStopped;
    private boolean fatalSessionError;
    private volatile long lastAudioActivityMs;

    public AudioEncoder(AudioCapture capture, Streamer streamer, Options options) {
        this.capture = capture;
        this.streamer = streamer;
        this.bitRate = options.getAudioBitRate();
        this.codecOptions = options.getAudioCodecOptions();
        this.encoderName = options.getAudioEncoder();
        this.audioUid = options.getAudioUid();
        this.pauseMediaOnRelease = options.getAudioStartMuted();
        this.captureEnabled = !options.getAudioStartMuted();
    }

    // LANADB: dynamically start or stop device audio capture while keeping
    // the audio stream and mirroring session alive.
    public synchronized void setCaptureEnabled(boolean enabled) {
        if (this.captureEnabled == enabled) {
            return;
        }
        Ln.d("Audio capture " + (enabled ? "enabled" : "disabled"));
        this.captureEnabled = enabled;
        notifyAll();
    }

    private static MediaFormat createFormat(String mimeType, int bitRate, List<CodecOption> codecOptions) {
        MediaFormat format = new MediaFormat();
        format.setString(MediaFormat.KEY_MIME, mimeType);
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitRate);
        format.setInteger(MediaFormat.KEY_CHANNEL_COUNT, CHANNELS);
        format.setInteger(MediaFormat.KEY_SAMPLE_RATE, SAMPLE_RATE);

        if (codecOptions != null) {
            for (CodecOption option : codecOptions) {
                String key = option.getKey();
                Object value = option.getValue();
                CodecUtils.setCodecOption(format, key, value);
                Ln.d("Audio codec option set: " + key + " (" + value.getClass().getSimpleName() + ") = " + value);
            }
        }

        return format;
    }

    @TargetApi(AndroidVersions.API_24_ANDROID_7_0)
    private void inputThread(MediaCodec mediaCodec, AudioCapture capture) throws IOException, InterruptedException {
        final MediaCodec.BufferInfo bufferInfo = new MediaCodec.BufferInfo();

        while (!Thread.currentThread().isInterrupted()) {
            InputTask task = inputTasks.take();
            ByteBuffer buffer = mediaCodec.getInputBuffer(task.index);
            int r = capture.read(buffer, bufferInfo);
            if (r <= 0) {
                throw new IOException("Could not read audio: " + r);
            }
            if (hasNonZeroPcm(buffer, bufferInfo)) {
                lastAudioActivityMs = SystemClock.uptimeMillis();
            }

            mediaCodec.queueInputBuffer(task.index, bufferInfo.offset, bufferInfo.size, bufferInfo.presentationTimeUs, bufferInfo.flags);
        }
    }

    private void outputThread(MediaCodec mediaCodec) throws IOException, InterruptedException {
        while (!Thread.currentThread().isInterrupted()) {
            OutputTask task = outputTasks.take();
            ByteBuffer buffer = mediaCodec.getOutputBuffer(task.index);
            try {
                if (recreatePts) {
                    fixTimestamp(task.bufferInfo);
                }
                streamer.writePacket(buffer, task.bufferInfo);
            } finally {
                mediaCodec.releaseOutputBuffer(task.index, false);
            }
        }
    }

    private void fixTimestamp(MediaCodec.BufferInfo bufferInfo) {
        assert recreatePts;

        if ((bufferInfo.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
            // Config packet, nothing to fix
            return;
        }

        long pts = bufferInfo.presentationTimeUs;
        if (previousPts != 0) {
            long now = System.nanoTime() / 1000;
            // This specific encoder produces PTS matching the exact number of samples
            long duration = pts - previousPts;
            bufferInfo.presentationTimeUs = now - duration;
        }

        previousPts = pts;
    }

    @Override
    public void start(TerminationListener listener) {
        thread = new Thread(() -> {
            boolean fatalError = false;
            try {
                encode();
            } catch (ConfigurationException e) {
                // Do not print stack trace, a user-friendly error-message has already been logged
                fatalError = true;
            } catch (AudioCaptureException e) {
                // Do not print stack trace, a user-friendly error-message has already been logged
            } catch (IOException e) {
                Ln.e("Audio encoding error", e);
                fatalError = true;
            } finally {
                Ln.d("Audio encoder stopped");
                listener.onTerminated(fatalError);
            }
        }, "audio-encoder");
        thread.start();
    }

    @Override
    public void stop() {
        if (thread != null) {
            // Just wake up the blocking wait from the thread, so that it properly releases all its resources and terminates
            end();
        }
    }

    @Override
    public void join() throws InterruptedException {
        if (thread != null) {
            thread.join();
        }
    }

    private synchronized void end() {
        ended = true;
        notifyAll();
    }

    private synchronized void endSession(boolean fatal) {
        sessionStopped = true;
        if (fatal) {
            fatalSessionError = true;
        }
        notifyAll();
    }

    private synchronized void waitSessionEnded() {
        try {
            while (!ended && captureEnabled && !sessionStopped) {
                wait();
            }
        } catch (InterruptedException e) {
            // ignore
        }
    }

    @TargetApi(AndroidVersions.API_23_ANDROID_6_0)
    private void encode() throws IOException, ConfigurationException, AudioCaptureException {
        if (Build.VERSION.SDK_INT < AndroidVersions.API_30_ANDROID_11) {
            Ln.w("Audio disabled: it is not supported before Android 11");
            streamer.writeDisableStream(false);
            return;
        }

        try {
            capture.checkCompatibility(); // throws an AudioCaptureException on error
        } catch (AudioCaptureException e) {
            // Notify the client that the audio could not be captured
            streamer.writeDisableStream(false);
            throw e;
        }

        // LANADB: write the codec header once so the client demuxer opens its
        // sinks immediately even when starting in the muted/paused state.
        streamer.writeAudioHeader();
        Codec codec = streamer.getCodec();

        while (true) {
            synchronized (this) {
                while (!ended && !captureEnabled) {
                    try {
                        wait();
                    } catch (InterruptedException e) {
                        return;
                    }
                }
                if (ended) {
                    return;
                }
                sessionStopped = false;
                fatalSessionError = false;
            }

            encodeSession(codec);

            synchronized (this) {
                if (ended || fatalSessionError) {
                    return;
                }
            }
        }
    }

    @TargetApi(AndroidVersions.API_23_ANDROID_6_0)
    private void encodeSession(Codec codec) throws ConfigurationException {
        inputTasks.clear();
        outputTasks.clear();
        previousPts = 0;

        MediaCodec mediaCodec = null;
        mediaCodecThread = null;
        inputThread = null;
        outputThread = null;

        boolean mediaCodecStarted = false;
        boolean captureStarted = false;
        lastAudioActivityMs = 0;
        try {
            mediaCodec = createMediaCodec(codec, encoderName);

            // The default OPUS and FLAC encoders overwrite the input PTS with a value that matches the number of samples. This is not the behavior
            // we want: it ignores any audio clock drift and hard silences (packets not produced on silence). To work around this behavior,
            // regenerate PTS based on the current time and the packet duration.
            String codecName = mediaCodec.getCanonicalName();
            recreatePts = "c2.android.opus.encoder".equals(codecName) || "c2.android.flac.encoder".equals(codecName);

            mediaCodecThread = new HandlerThread("media-codec");
            mediaCodecThread.start();

            MediaFormat format = createFormat(codec.getMimeType(), bitRate, codecOptions);
            mediaCodec.setCallback(new EncoderCallback(), new Handler(mediaCodecThread.getLooper()));
            mediaCodec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);

            capture.start();
            captureStarted = true;

            final MediaCodec mediaCodecRef = mediaCodec;
            inputThread = new Thread(() -> {
                try {
                    inputThread(mediaCodecRef, capture);
                } catch (IOException | InterruptedException e) {
                    if (!Thread.currentThread().isInterrupted()) {
                        Ln.e("Audio capture error", e);
                    }
                } finally {
                    endSession(false);
                }
            }, "audio-in");

            outputThread = new Thread(() -> {
                try {
                    outputThread(mediaCodecRef);
                } catch (InterruptedException e) {
                    // this is expected on pause or close
                } catch (IOException e) {
                    // Broken pipe is expected on close, because the socket is closed by the client
                    if (!IO.isBrokenPipe(e)) {
                        Ln.e("Audio encoding error", e);
                    }
                    endSession(true);
                    return;
                } finally {
                    endSession(false);
                }
            }, "audio-out");

            mediaCodec.start();
            mediaCodecStarted = true;
            inputThread.start();
            outputThread.start();

            waitSessionEnded();
        } catch (AudioCaptureException e) {
            Ln.w("Audio capture session could not start");
            synchronized (this) {
                captureEnabled = false;
            }
        } catch (IOException e) {
            Ln.e("Audio encoder setup error", e);
            synchronized (this) {
                captureEnabled = false;
            }
        } finally {
            // LANADB: if this session actively captured device audio, pause
            // playing media and wait briefly BEFORE releasing AudioCapture so
            // the phone speaker does not suddenly burst out loud (like
            // disconnecting Bluetooth headphones).
            if (captureStarted && pauseMediaOnRelease && shouldPauseMediaBeforeRelease()) {
                pauseDeviceMediaBeforeRelease();
            }

            // Cleanup everything (either on mute/pause, error, or shutdown)
            if (mediaCodecThread != null) {
                Looper looper = mediaCodecThread.getLooper();
                if (looper != null) {
                    looper.quitSafely();
                }
            }
            if (inputThread != null) {
                inputThread.interrupt();
            }
            if (outputThread != null) {
                outputThread.interrupt();
            }

            try {
                if (mediaCodecThread != null) {
                    mediaCodecThread.join();
                }
                if (inputThread != null) {
                    inputThread.join();
                }
                if (outputThread != null) {
                    outputThread.join();
                }
            } catch (InterruptedException e) {
                // Should never happen
                throw new AssertionError(e);
            }

            if (mediaCodec != null) {
                if (mediaCodecStarted) {
                    mediaCodec.stop();
                }
                mediaCodec.release();
            }
            if (capture != null) {
                capture.stop();
            }
            inputTasks.clear();
            outputTasks.clear();
        }
    }

    // LANADB: lightweight check on 16-bit PCM to detect whether the captured
    // audio source actually produced non-silent samples.
    private static boolean hasNonZeroPcm(ByteBuffer buffer, MediaCodec.BufferInfo info) {
        int start = info.offset;
        int end = Math.min(buffer.limit(), start + info.size);
        for (int i = start; i + 1 < end; i += 64) {
            if (buffer.get(i) != 0 || buffer.get(i + 1) != 0) {
                return true;
            }
        }
        return false;
    }

    // LANADB: pause only when media is actually active. For single-app windows
    // (audioUid >= 0), require recent audio from that app so unrelated music on
    // the main screen is not interrupted when the single app is silent.
    private boolean shouldPauseMediaBeforeRelease() {
        long last = lastAudioActivityMs;
        if (last > 0 && (SystemClock.uptimeMillis() - last) <= RECENT_AUDIO_WINDOW_MS) {
            return true;
        }
        if (audioUid >= 0) {
            return false;
        }
        try {
            AudioManager audioManager = (AudioManager) FakeContext.get().getSystemService(Context.AUDIO_SERVICE);
            return audioManager != null && audioManager.isMusicActive();
        } catch (Exception e) {
            return false;
        }
    }

    // LANADB: resolve ISessionManager binder proxy once per pause attempt.
    @SuppressLint("PrivateApi")
    private static Object getMediaSessionManager() {
        try {
            Class<?> smClass = Class.forName("android.os.ServiceManager");
            Method getService = smClass.getDeclaredMethod("getService", String.class);
            IBinder binder = (IBinder) getService.invoke(null, "media_session");
            if (binder == null) {
                return null;
            }
            Class<?> stubClass = Class.forName("android.media.session.ISessionManager$Stub");
            return stubClass.getDeclaredMethod("asInterface", IBinder.class).invoke(null, binder);
        } catch (Exception e) {
            Ln.d("Could not obtain ISessionManager: " + e.getMessage());
            return null;
        }
    }

    // LANADB: invoke ISessionController.pause() directly on active sessions
    // (compatible with both MediaSession.Token and raw IBinder lists across
    // Android versions, and both pause(String) and pause() signatures).
    // Only pauses non-paused states (PLAYING/BUFFERING/FF/REW or null state)
    // and filters by target package when audioUid >= 0 to avoid disturbing
    // unrelated apps on the main display.
    @SuppressLint("PrivateApi")
    private static void pauseActiveMediaSessions(Object sessionManager, int audioUid) {
        if (sessionManager == null) {
            return;
        }
        try {
            List<?> sessions = null;
            try {
                Method getSessions = sessionManager.getClass().getDeclaredMethod(
                        "getSessions", ComponentName.class, int.class);
                sessions = (List<?>) getSessions.invoke(sessionManager, null, 0);
            } catch (NoSuchMethodException e) {
                for (Method m : sessionManager.getClass().getDeclaredMethods()) {
                    if ("getSessions".equals(m.getName()) && m.getParameterTypes().length == 2) {
                        sessions = (List<?>) m.invoke(sessionManager, null, 0);
                        break;
                    }
                }
            }
            if (sessions == null || sessions.isEmpty()) {
                return;
            }

            Set<String> targetPackages = null;
            if (audioUid >= 0) {
                try {
                    PackageManager pm = FakeContext.get().getPackageManager();
                    String[] pkgs = pm != null ? pm.getPackagesForUid(audioUid) : null;
                    if (pkgs != null && pkgs.length > 0) {
                        targetPackages = new HashSet<>(Arrays.asList(pkgs));
                    }
                } catch (Exception e) {
                    Ln.d("Could not resolve packages for audioUid " + audioUid + ": " + e.getMessage());
                }
            }

            Method tokenGetBinder = null;
            Class<?> ctrlStubClass = null;
            for (Object item : sessions) {
                if (item == null) {
                    continue;
                }
                try {
                    Object controller = null;
                    if (item instanceof MediaSession.Token) {
                        if (tokenGetBinder == null) {
                            tokenGetBinder = MediaSession.Token.class.getDeclaredMethod("getBinder");
                        }
                        controller = tokenGetBinder.invoke(item);
                    } else if (item instanceof IBinder) {
                        if (ctrlStubClass == null) {
                            ctrlStubClass = Class.forName("android.media.session.ISessionController$Stub");
                        }
                        controller = ctrlStubClass.getDeclaredMethod("asInterface", IBinder.class)
                                .invoke(null, item);
                    }
                    if (controller == null) {
                        continue;
                    }

                    if (targetPackages != null) {
                        try {
                            String pkg = (String) controller.getClass()
                                    .getDeclaredMethod("getPackageName").invoke(controller);
                            if (pkg != null && !targetPackages.contains(pkg)) {
                                continue;
                            }
                        } catch (Exception e) {
                            // Ignore package lookup error and fall through safely
                        }
                    }

                    boolean shouldPause = true;
                    try {
                        Object stateObj = controller.getClass()
                                .getDeclaredMethod("getPlaybackState").invoke(controller);
                        if (stateObj instanceof PlaybackState) {
                            int state = ((PlaybackState) stateObj).getState();
                            shouldPause = state == PlaybackState.STATE_PLAYING
                                    || state == PlaybackState.STATE_BUFFERING
                                    || state == PlaybackState.STATE_FAST_FORWARDING
                                    || state == PlaybackState.STATE_REWINDING;
                        }
                    } catch (Exception e) {
                        // If state cannot be queried, pure pause() is still safe (never toggles play)
                    }

                    if (!shouldPause) {
                        continue;
                    }

                    try {
                        Method pauseWithPkg = controller.getClass().getDeclaredMethod("pause", String.class);
                        pauseWithPkg.invoke(controller, FakeContext.PACKAGE_NAME);
                    } catch (NoSuchMethodException e) {
                        Method pauseNoArg = controller.getClass().getDeclaredMethod("pause");
                        pauseNoArg.invoke(controller);
                    }
                } catch (Exception e) {
                    Ln.d("Could not pause individual media session: " + e.getMessage());
                }
            }
        } catch (Exception e) {
            Ln.d("Could not enumerate active media sessions: " + e.getMessage());
        }
    }

    // LANADB: dispatch pure KEYCODE_MEDIA_PAUSE directly to MediaSessionService
    // (same path as `cmd media_session dispatch pause`), reaching the active
    // media button session and its mediaButtonReceiver without needing an
    // application Context.
    @SuppressLint("PrivateApi")
    private static boolean dispatchMediaPauseToSessionService(Object sessionManager) {
        if (sessionManager == null) {
            return false;
        }
        try {
            Method dispatch = sessionManager.getClass().getDeclaredMethod(
                    "dispatchMediaKeyEvent", String.class, boolean.class, KeyEvent.class, boolean.class);
            long now = SystemClock.uptimeMillis();
            KeyEvent down = new KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PAUSE, 0);
            KeyEvent up = new KeyEvent(now, now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MEDIA_PAUSE, 0);
            dispatch.invoke(sessionManager, FakeContext.PACKAGE_NAME, false, down, false);
            dispatch.invoke(sessionManager, FakeContext.PACKAGE_NAME, false, up, false);
            return true;
        } catch (Exception e) {
            Ln.w("Could not dispatch KEYCODE_MEDIA_PAUSE to media_session", e);
            return false;
        }
    }

    // LANADB: pause active media using ISessionController.pause(), pure
    // KEYCODE_MEDIA_PAUSE (never toggle play/pause), plus an immediate
    // non-fadeable AUDIOFOCUS_GAIN preemption for apps that ignore media keys,
    // then drain briefly while AudioCapture still holds the route.
    private void pauseDeviceMediaBeforeRelease() {
        AudioManager audioManager = null;
        AudioFocusRequest focusRequest = null;
        boolean focusRequested = false;
        try {
            Object sessionManager = getMediaSessionManager();

            // 1. Directly pause active MediaSession controllers (reaches
            // multi-session setups and apps implementing MediaSession.Callback.onPause
            // without a mediaButtonReceiver).
            pauseActiveMediaSessions(sessionManager, audioUid);

            // 2. Pure KEYCODE_MEDIA_PAUSE via MediaSessionService (reaches
            // active media button session / mediaButtonReceiver directly),
            // falling back to InputManager key injection.
            if (!dispatchMediaPauseToSessionService(sessionManager)) {
                try {
                    Device.pressReleaseKeycode(KeyEvent.KEYCODE_MEDIA_PAUSE, Device.DISPLAY_ID_NONE, Device.INJECT_MODE_ASYNC);
                } catch (Exception e) {
                    Ln.w("Could not inject KEYCODE_MEDIA_PAUSE", e);
                }
            }

            // 3. Immediate AUDIOFOCUS_GAIN preemption using USAGE_VOICE_COMMUNICATION
            // + CONTENT_TYPE_SPEECH so Android 12+ FadeOutManager does NOT delay
            // AUDIOFOCUS_LOSS with a 2000ms fade-out (which would otherwise be
            // cancelled when we abandon focus after PAUSE_DRAIN_DELAY_MS).
            try {
                audioManager = (AudioManager) FakeContext.get().getSystemService(Context.AUDIO_SERVICE);
                if (audioManager != null && Build.VERSION.SDK_INT >= AndroidVersions.API_26_ANDROID_8_0) {
                    AudioAttributes attrs = new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build();
                    focusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                            .setAudioAttributes(attrs)
                            .setOnAudioFocusChangeListener(focusChange -> {
                                // no-op
                            })
                            .build();
                    audioManager.requestAudioFocus(focusRequest);
                    focusRequested = true;
                }
            } catch (Exception e) {
                Ln.w("Could not request temporary audio focus", e);
            }

            Ln.d("Paused device media before releasing audio capture");
            SystemClock.sleep(PAUSE_DRAIN_DELAY_MS);
        } finally {
            if (focusRequested && audioManager != null && focusRequest != null
                    && Build.VERSION.SDK_INT >= AndroidVersions.API_26_ANDROID_8_0) {
                try {
                    audioManager.abandonAudioFocusRequest(focusRequest);
                } catch (Exception e) {
                    Ln.w("Could not abandon temporary audio focus", e);
                }
            }
        }
    }

    private static MediaCodec createMediaCodec(Codec codec, String encoderName) throws IOException, ConfigurationException {
        if (encoderName != null) {
            Ln.d("Creating audio encoder by name: '" + encoderName + "'");
            try {
                MediaCodec mediaCodec = MediaCodec.createByCodecName(encoderName);
                String mimeType = Codec.getMimeType(mediaCodec);
                if (!codec.getMimeType().equals(mimeType)) {
                    Ln.e("Audio encoder type for \"" + encoderName + "\" (" + mimeType + ") does not match codec type (" + codec.getMimeType() + ")");
                    throw new ConfigurationException("Incorrect encoder type: " + encoderName);
                }
                return mediaCodec;
            } catch (IllegalArgumentException e) {
                Ln.e("Audio encoder '" + encoderName + "' for " + codec.getName() + " not found\n" + LogUtils.buildAudioEncoderListMessage());
                throw new ConfigurationException("Unknown encoder: " + encoderName);
            } catch (IOException e) {
                Ln.e("Could not create audio encoder '" + encoderName + "' for " + codec.getName() + "\n" + LogUtils.buildAudioEncoderListMessage());
                throw e;
            }
        }

        try {
            MediaCodec mediaCodec = MediaCodec.createEncoderByType(codec.getMimeType());
            Ln.d("Using audio encoder: '" + mediaCodec.getName() + "'");
            return mediaCodec;
        } catch (IOException | IllegalArgumentException e) {
            Ln.e("Could not create default audio encoder for " + codec.getName() + "\n" + LogUtils.buildAudioEncoderListMessage());
            throw e;
        }
    }

    private final class EncoderCallback extends MediaCodec.Callback {
        @TargetApi(AndroidVersions.API_24_ANDROID_7_0)
        @Override
        public void onInputBufferAvailable(MediaCodec codec, int index) {
            try {
                inputTasks.put(new InputTask(index));
            } catch (InterruptedException e) {
                endSession(false);
            }
        }

        @Override
        public void onOutputBufferAvailable(MediaCodec codec, int index, MediaCodec.BufferInfo bufferInfo) {
            try {
                outputTasks.put(new OutputTask(index, bufferInfo));
            } catch (InterruptedException e) {
                endSession(false);
            }
        }

        @Override
        public void onError(MediaCodec codec, MediaCodec.CodecException e) {
            Ln.e("MediaCodec error", e);
            endSession(false);
        }

        @Override
        public void onOutputFormatChanged(MediaCodec codec, MediaFormat format) {
            // ignore
        }
    }
}
