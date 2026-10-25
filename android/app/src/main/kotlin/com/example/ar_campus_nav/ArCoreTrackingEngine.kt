package com.example.ar_campus_nav

import android.app.Activity
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Config
import com.google.ar.core.Pose
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import com.google.ar.core.exceptions.CameraNotAvailableException
import com.google.ar.core.exceptions.UnavailableApkTooOldException
import com.google.ar.core.exceptions.UnavailableArcoreNotInstalledException
import com.google.ar.core.exceptions.UnavailableDeviceNotCompatibleException
import com.google.ar.core.exceptions.UnavailableSdkTooOldException
import com.google.ar.core.exceptions.UnavailableUserDeclinedInstallationException
import io.flutter.plugin.common.EventChannel
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

class ArCoreTrackingEngine(
    private val activity: Activity,
    private val poseSinkProvider: () -> EventChannel.EventSink?,
    private val onNavigationClosed: (() -> Unit)? = null,
) : GLSurfaceView.Renderer {
    data class RoutePoint(
        val rightMeters: Float,
        val forwardMeters: Float,
        val label: String,
        val semantic: Boolean,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val backgroundRenderer = ArCameraBackgroundRenderer()
    private val breadcrumbRenderer = ArBreadcrumbRenderer()

    private var session: Session? = null
    private var surfaceView: GLSurfaceView? = null
    private var navigationOverlay: FrameLayout? = null
    private var navigationStatusText: TextView? = null
    private var navigationArrowText: TextView? = null
    private var navigationAlignButton: Button? = null
    private var navigationReanchorButton: Button? = null
    private var navigationExitButton: Button? = null
    private var cameraTextureId: Int = 0

    // Tracking/mapping origin: gravity-horizontal frame.
    // This intentionally ignores the phone's pitch/roll at startup.
    private var trackingOriginPosition: FloatArray? = null
    private var trackingForwardX = 0f
    private var trackingForwardZ = -1f
    private var trackingRightX = 1f
    private var trackingRightZ = 0f

    // Navigation alignment frame: also gravity-horizontal.
    private var navigationOriginPosition: FloatArray? = null
    private var navigationForwardX = 0f
    private var navigationForwardZ = -1f
    private var navigationRightX = 1f
    private var navigationRightZ = 0f

    private var latestCameraPose: Pose? = null
    private var sessionResumed = false
    private var started = false
    private var lastEmitNanos = 0L
    private var lastHudNanos = 0L

    // Camera tracking status is state-like, not frame-like.  Without this
    // guard PAUSED/STOPPED was being pushed over the EventChannel every GL
    // frame, which could flood Flutter and make the mapper look frozen.
    private var lastCameraTrackingState: String? = null
    private var lastCameraTrackingReason: String? = null

    private var navigationMode = false
    private var navigationAligned = false
    private var alignmentRequested = false

    // Pass 8.5 robust alignment.
    // Translation is fixed at Point A, but direction is no longer inferred from
    // one fragile A->B vector. We collect a short ARCore trajectory and fit its
    // dominant horizontal direction, then reject curved/unstable calibration.
    private var navigationCalibrationStart: FloatArray? = null
    private var navigationCalibrationReady = false
    private val navigationCalibrationSamples = ArrayList<FloatArray>()
    private var navigationCalibrationPathMeters = 0f
    private var navigationCalibrationLastSample: FloatArray? = null
    private val navigationCalibrationMinMeters = 2.00f
    private val navigationCalibrationMinSamples = 10
    private val navigationCalibrationMinStraightness = 0.86f
    private val navigationCalibrationMaxLateralRmsMeters = 0.42f

    // Once navigation is aligned the venue->AR transform is locked. If ARCore
    // pauses, resumes with a large discontinuity, or produces impossible pose
    // jumps, guidance freezes instead of silently moving the whole venue.
    private var navigationTrackingLost = false
    private var navigationTrackingLostAtNanos = 0L
    private var navigationPositionUncertain = false
    private var navigationLastAcceptedPosition: FloatArray? = null
    private var navigationLastAcceptedTimestampNanos = 0L
    private var navigationRejectedJumpCount = 0
    private val navigationRecoveryMaxJumpMeters = 1.75f
    private val navigationJumpBaseMeters = 0.80f
    private val navigationMaxPlausibleSpeedMps = 4.50f

    private var navigationDestination = ""
    private var navigationStartLabel = "Route start"
    private var navigationAnchorLocalized = false
    private var navigationPoints: List<RoutePoint> = emptyList()
    private var activeRouteIndex = 1
    private var navigationArrivalShown = false

    fun availabilityLabel(): String {
        return try {
            when (ArCoreApk.getInstance().checkAvailability(activity)) {
                ArCoreApk.Availability.SUPPORTED_INSTALLED ->
                    "SUPPORTED_INSTALLED"
                ArCoreApk.Availability.SUPPORTED_APK_TOO_OLD ->
                    "SUPPORTED_APK_TOO_OLD"
                ArCoreApk.Availability.SUPPORTED_NOT_INSTALLED ->
                    "SUPPORTED_NOT_INSTALLED"
                ArCoreApk.Availability.UNKNOWN_CHECKING ->
                    "CHECKING"
                ArCoreApk.Availability.UNKNOWN_TIMED_OUT ->
                    "CHECK_TIMED_OUT"
                ArCoreApk.Availability.UNKNOWN_ERROR ->
                    "CHECK_ERROR"
                ArCoreApk.Availability.UNSUPPORTED_DEVICE_NOT_CAPABLE ->
                    "UNSUPPORTED"
            }
        } catch (error: Exception) {
            "ERROR:${error.javaClass.simpleName}"
        }
    }

    fun start(): String {
        navigationMode = false
        return startSession()
    }

    fun startNavigation(
        destination: String,
        points: List<RoutePoint>,
        startLabel: String = "Route start",
        anchorLocalized: Boolean = false,
    ): String {
        if (points.size < 2) return "ROUTE_TOO_SHORT"

        navigationMode = true
        navigationDestination = destination
        navigationStartLabel = startLabel
        navigationAnchorLocalized = anchorLocalized
        navigationPoints = points
        navigationAligned = false
        alignmentRequested = false
        resetNavigationCalibration()
        resetNavigationContinuity()
        activeRouteIndex = 1
        navigationArrivalShown = false

        return startSession()
    }

    private fun startSession(): String {
        if (started) return "STARTED"

        try {
            val installStatus = ArCoreApk.getInstance().requestInstall(activity, true)
            if (installStatus == ArCoreApk.InstallStatus.INSTALL_REQUESTED) {
                return "INSTALL_REQUESTED"
            }
        } catch (error: UnavailableDeviceNotCompatibleException) {
            return "UNSUPPORTED_DEVICE"
        } catch (error: UnavailableUserDeclinedInstallationException) {
            return "INSTALL_DECLINED"
        } catch (error: UnavailableArcoreNotInstalledException) {
            return "ARCORE_NOT_INSTALLED"
        } catch (error: UnavailableApkTooOldException) {
            return "ARCORE_APK_TOO_OLD"
        } catch (error: UnavailableSdkTooOldException) {
            return "SDK_TOO_OLD"
        } catch (error: Exception) {
            return "START_ERROR:${error.javaClass.simpleName}:${error.message ?: "unknown"}"
        }

        return try {
            val newSession = Session(activity)
            val config = Config(newSession).apply {
                focusMode = Config.FocusMode.AUTO
                updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                planeFindingMode = Config.PlaneFindingMode.DISABLED
                lightEstimationMode = Config.LightEstimationMode.DISABLED
            }
            newSession.configure(config)
            session = newSession

            val glView = GLSurfaceView(activity).apply {
                setEGLContextClientVersion(2)
                preserveEGLContextOnPause = true
                setRenderer(this@ArCoreTrackingEngine)
                renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
            }

            if (navigationMode) {
                createNavigationOverlay(glView)
            } else {
                val layoutParams = FrameLayout.LayoutParams(2, 2).apply {
                    gravity = Gravity.BOTTOM or Gravity.END
                }
                activity.addContentView(glView, layoutParams)
            }

            surfaceView = glView
            clearTrackingOrigin()
            clearNavigationFrame()
            latestCameraPose = null
            cameraTextureId = 0
            lastEmitNanos = 0L
            lastHudNanos = 0L
            lastCameraTrackingState = null
            lastCameraTrackingReason = null
            started = true

            resume()
            "STARTED"
        } catch (error: UnavailableDeviceNotCompatibleException) {
            cleanupFailedStart()
            "UNSUPPORTED_DEVICE"
        } catch (error: UnavailableArcoreNotInstalledException) {
            cleanupFailedStart()
            "ARCORE_NOT_INSTALLED"
        } catch (error: UnavailableApkTooOldException) {
            cleanupFailedStart()
            "ARCORE_APK_TOO_OLD"
        } catch (error: UnavailableSdkTooOldException) {
            cleanupFailedStart()
            "SDK_TOO_OLD"
        } catch (error: Exception) {
            cleanupFailedStart()
            "START_ERROR:${error.javaClass.simpleName}:${error.message ?: "unknown"}"
        }
    }

    fun resetOrigin() {
        clearTrackingOrigin()
        if (navigationMode) {
            clearNavigationFrame()
            navigationAligned = false
        }
        emitStatus("RESETTING_ORIGIN")
    }

    fun pause() {
        if (!started) return
        surfaceView?.onPause()
        if (sessionResumed) {
            session?.pause()
            sessionResumed = false
        }
    }

    fun resume() {
        if (!started) return
        try {
            if (!sessionResumed) {
                session?.resume()
                sessionResumed = true
            }
            surfaceView?.onResume()
        } catch (error: CameraNotAvailableException) {
            emitError("CAMERA_NOT_AVAILABLE", error.message)
        }
    }

    fun stop() {
        if (!started && session == null && surfaceView == null) return

        pause()

        val oldOverlay = navigationOverlay
        val oldView = surfaceView
        navigationOverlay = null
        navigationStatusText = null
        navigationArrowText = null
        navigationAlignButton = null
        navigationReanchorButton = null
        navigationExitButton = null
        surfaceView = null

        val removeViews = Runnable {
            (oldOverlay?.parent as? ViewGroup)?.removeView(oldOverlay)
            if (oldOverlay == null) {
                (oldView?.parent as? ViewGroup)?.removeView(oldView)
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            removeViews.run()
        } else {
            mainHandler.post(removeViews)
        }

        try {
            session?.close()
        } catch (_: Exception) {
        }

        session = null
        clearTrackingOrigin()
        clearNavigationFrame()
        latestCameraPose = null
        cameraTextureId = 0
        lastEmitNanos = 0L
        lastHudNanos = 0L
        started = false
        sessionResumed = false
        navigationMode = false
        navigationAligned = false
        alignmentRequested = false
        resetNavigationCalibration()
        resetNavigationContinuity()
        navigationArrivalShown = false
        navigationPoints = emptyList()
        emitStatus("STOPPED")
    }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        cameraTextureId = textures[0]

        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTextureId)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MIN_FILTER,
            GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MAG_FILTER,
            GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_S,
            GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_T,
            GLES20.GL_CLAMP_TO_EDGE,
        )

        session?.setCameraTextureName(cameraTextureId)

        if (navigationMode) {
            backgroundRenderer.createOnGlThread()
            breadcrumbRenderer.createOnGlThread()
        }
    }

    @Suppress("DEPRECATION")
    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        GLES20.glViewport(0, 0, width, height)
        session?.setDisplayGeometry(
            activity.windowManager.defaultDisplay.rotation,
            width,
            height,
        )
    }

    override fun onDrawFrame(gl: GL10?) {
        val activeSession = session ?: return
        if (!sessionResumed || cameraTextureId == 0) return

        try {
            val frame = activeSession.update()
            val camera = frame.camera

            if (navigationMode) {
                backgroundRenderer.draw(frame, cameraTextureId)
            }

            if (camera.trackingState != TrackingState.TRACKING) {
                val reason = camera.trackingFailureReason.name
                emitTrackingState(
                    state = camera.trackingState.name,
                    reason = reason,
                )
                if (navigationMode) {
                    if (!navigationTrackingLost) {
                        navigationTrackingLost = true
                        navigationTrackingLostAtNanos = frame.timestamp
                    }
                    setNavigationArrowVisible(false)
                    setNavigationHud(
                        "TRACKING LOST — STOP WALKING\n" +
                            (
                                trackingFailureMessage(reason) ?:
                                    "Move the phone slowly until ARCore is tracking."
                            ),
                    )
                }
                return
            }

            val currentPose = camera.pose
            latestCameraPose = currentPose

            if (navigationMode && navigationTrackingLost) {
                if (!handleNavigationTrackingRecovery(
                        currentPose = currentPose,
                        timestampNanos = frame.timestamp,
                    )
                ) {
                    return
                }
            }

            // A pose event itself tells Flutter that tracking is healthy.
            // Reset the status de-duplication latch so a future PAUSED state
            // will still be delivered even if it has the same reason as before.
            lastCameraTrackingState = "TRACKING"
            lastCameraTrackingReason = null

            if (navigationMode) {
                if (alignmentRequested) {
                    if (navigationCalibrationStart == null) {
                        captureNavigationCalibrationStart(currentPose)
                    } else if (navigationCalibrationReady) {
                        completeNavigationCalibration(currentPose)
                    }
                    alignmentRequested = false
                }

                if (!navigationAligned) {
                    if (navigationCalibrationStart != null) {
                        updateNavigationCalibrationProgress(
                            currentPose = currentPose,
                            timestampNanos = frame.timestamp,
                        )
                    }
                    emitTrackingState("TRACKING")
                    setNavigationArrowVisible(false)
                    return
                }

                if (navigationPositionUncertain) {
                    return
                }

                if (!acceptNavigationPose(
                        currentPose = currentPose,
                        timestampNanos = frame.timestamp,
                    )
                ) {
                    return
                }

                val local = navigationLocalPosition(currentPose)
                emitHorizontalPose(
                    currentPose = currentPose,
                    local = local,
                    timestampNanos = frame.timestamp,
                    originForwardX = navigationForwardX,
                    originForwardZ = navigationForwardZ,
                    originRightX = navigationRightX,
                    originRightZ = navigationRightZ,
                )

                val worldPoints = routeWorldPoints()
                updateNavigationProgress(
                    currentPose = currentPose,
                    local = local,
                    worldPoints = worldPoints,
                    timestampNanos = frame.timestamp,
                )

                if (worldPoints.isNotEmpty() &&
                    activeRouteIndex < worldPoints.size
                ) {
                    val routeY = navigationOriginPosition?.get(1)
                        ?.minus(1.10f)
                        ?: currentPose.ty().minus(1.10f)
                    val userWorldPoint = floatArrayOf(
                        currentPose.tx(),
                        routeY,
                        currentPose.tz(),
                    )

                    breadcrumbRenderer.draw(
                        camera,
                        worldPoints,
                        activeRouteIndex.coerceAtMost(worldPoints.lastIndex),
                        userWorldPoint,
                    )
                }
                return
            }

            if (trackingOriginPosition == null) {
                establishTrackingOrigin(currentPose)
            }

            val local = trackingLocalPosition(currentPose)
            emitHorizontalPose(
                currentPose = currentPose,
                local = local,
                timestampNanos = frame.timestamp,
                originForwardX = trackingForwardX,
                originForwardZ = trackingForwardZ,
                originRightX = trackingRightX,
                originRightZ = trackingRightZ,
            )
        } catch (error: CameraNotAvailableException) {
            emitError("CAMERA_NOT_AVAILABLE", error.message)
        } catch (error: Exception) {
            emitError(error.javaClass.simpleName, error.message)
        }
    }

    private data class LocalPosition(
        val right: Float,
        val up: Float,
        val forward: Float,
    )

    private fun horizontalForward(pose: Pose): FloatArray {
        val forward = pose.getTransformedAxis(2, -1.0f)
        val length = sqrt(
            forward[0] * forward[0] +
                forward[2] * forward[2],
        )

        if (length < 0.0001f) {
            return floatArrayOf(0f, 0f, -1f)
        }

        return floatArrayOf(
            forward[0] / length,
            0f,
            forward[2] / length,
        )
    }

    private fun establishTrackingOrigin(pose: Pose) {
        val forward = horizontalForward(pose)
        trackingOriginPosition = pose.translation.copyOf()
        trackingForwardX = forward[0]
        trackingForwardZ = forward[2]
        trackingRightX = -trackingForwardZ
        trackingRightZ = trackingForwardX
    }

    private fun clearTrackingOrigin() {
        trackingOriginPosition = null
        trackingForwardX = 0f
        trackingForwardZ = -1f
        trackingRightX = 1f
        trackingRightZ = 0f
    }

    private data class CalibrationFit(
        val forwardX: Float,
        val forwardZ: Float,
        val displacementMeters: Float,
        val pathMeters: Float,
        val straightness: Float,
        val lateralRmsMeters: Float,
        val sampleCount: Int,
    )

    private fun captureNavigationCalibrationStart(pose: Pose) {
        resetNavigationCalibration()

        val start = pose.translation.copyOf()
        navigationCalibrationStart = start
        navigationOriginPosition = start.copyOf()
        navigationCalibrationSamples.add(start.copyOf())
        navigationCalibrationLastSample = start.copyOf()

        mainHandler.post {
            navigationAlignButton?.apply {
                text = "WALK 2.0 M"
                isEnabled = false
                alpha = 0.55f
            }
        }

        setNavigationHud(
            (
                if (navigationAnchorLocalized) {
                    "Anchor fixed: $navigationStartLabel. "
                } else {
                    "Start fixed here. "
                }
            ) +
                "Walk naturally along the first real route for about 2–3 m. " +
                "Small hand wobble is fine; do not deliberately curve or turn yet.",
        )
    }

    private fun updateNavigationCalibrationProgress(
        currentPose: Pose,
        timestampNanos: Long,
    ) {
        val start = navigationCalibrationStart ?: return
        appendNavigationCalibrationSample(currentPose.translation)

        val translation = currentPose.translation
        val dx = translation[0] - start[0]
        val dz = translation[2] - start[2]
        val displacement = sqrt(dx * dx + dz * dz)

        val ready =
            displacement >= navigationCalibrationMinMeters &&
                navigationCalibrationSamples.size >= navigationCalibrationMinSamples

        if (ready != navigationCalibrationReady) {
            navigationCalibrationReady = ready
            mainHandler.post {
                navigationAlignButton?.apply {
                    isEnabled = ready
                    alpha = if (ready) 1f else 0.55f
                    text = if (ready) "LOCK DIRECTION" else "WALK 2.0 M"
                }
            }
        }

        if (timestampNanos - lastHudNanos < 160_000_000L) return
        lastHudNanos = timestampNanos

        val fit = navigationCalibrationFit()
        if (ready && fit != null) {
            setNavigationHud(
                "Direction sample: ${"%.1f".format(fit.displacementMeters)} m • " +
                    "${(fit.straightness * 100f).toInt()}% straight\\n" +
                    "Tap LOCK DIRECTION to validate and start guidance.",
            )
        } else {
            val remaining =
                (navigationCalibrationMinMeters - displacement).coerceAtLeast(0f)
            setNavigationHud(
                "Start fixed. Walk ${"%.1f".format(remaining)} m more " +
                    "along the first real route.",
            )
        }
    }

    private fun appendNavigationCalibrationSample(translation: FloatArray) {
        val last = navigationCalibrationLastSample
        if (last == null) {
            navigationCalibrationSamples.add(translation.copyOf())
            navigationCalibrationLastSample = translation.copyOf()
            return
        }

        val dx = translation[0] - last[0]
        val dz = translation[2] - last[2]
        val step = sqrt(dx * dx + dz * dz)

        // Ignore sub-centimeter pose noise while still keeping enough samples
        // for a stable line fit.
        if (step < 0.025f) return

        navigationCalibrationPathMeters += step
        navigationCalibrationSamples.add(translation.copyOf())
        navigationCalibrationLastSample = translation.copyOf()
    }

    private fun navigationCalibrationFit(): CalibrationFit? {
        val samples = navigationCalibrationSamples
        if (samples.size < 2) return null

        val start = samples.first()
        val end = samples.last()
        val endDx = end[0] - start[0]
        val endDz = end[2] - start[2]
        val displacement = sqrt(endDx * endDx + endDz * endDz)
        if (displacement < 0.0001f) return null

        var meanX = 0f
        var meanZ = 0f
        for (sample in samples) {
            meanX += sample[0]
            meanZ += sample[2]
        }
        meanX /= samples.size.toFloat()
        meanZ /= samples.size.toFloat()

        var covXX = 0f
        var covXZ = 0f
        var covZZ = 0f
        for (sample in samples) {
            val x = sample[0] - meanX
            val z = sample[2] - meanZ
            covXX += x * x
            covXZ += x * z
            covZZ += z * z
        }

        var angle = 0.5f * atan2(2f * covXZ, covXX - covZZ)
        var forwardX = cos(angle)
        var forwardZ = sin(angle)

        // PCA axis has no sign. Orient it from the physical calibration start
        // toward the end of the walk.
        if (forwardX * endDx + forwardZ * endDz < 0f) {
            forwardX = -forwardX
            forwardZ = -forwardZ
        }

        var lateralSquared = 0f
        for (sample in samples) {
            val dx = sample[0] - start[0]
            val dz = sample[2] - start[2]
            val lateral = dx * (-forwardZ) + dz * forwardX
            lateralSquared += lateral * lateral
        }

        val lateralRms = sqrt(lateralSquared / samples.size.toFloat())
        val path = navigationCalibrationPathMeters.coerceAtLeast(displacement)
        val straightness = (displacement / path).coerceIn(0f, 1f)

        return CalibrationFit(
            forwardX = forwardX,
            forwardZ = forwardZ,
            displacementMeters = displacement,
            pathMeters = path,
            straightness = straightness,
            lateralRmsMeters = lateralRms,
            sampleCount = samples.size,
        )
    }

    private fun completeNavigationCalibration(pose: Pose) {
        appendNavigationCalibrationSample(pose.translation)

        val fit = navigationCalibrationFit()
        if (fit == null ||
            fit.displacementMeters < navigationCalibrationMinMeters ||
            fit.sampleCount < navigationCalibrationMinSamples
        ) {
            navigationCalibrationReady = false
            return
        }

        if (fit.straightness < navigationCalibrationMinStraightness ||
            fit.lateralRmsMeters > navigationCalibrationMaxLateralRmsMeters
        ) {
            rejectNavigationCalibration(fit)
            return
        }

        val start = navigationCalibrationStart ?: return
        navigationOriginPosition = start.copyOf()
        navigationForwardX = fit.forwardX
        navigationForwardZ = fit.forwardZ
        navigationRightX = -navigationForwardZ
        navigationRightZ = navigationForwardX
        navigationAligned = true
        navigationCalibrationReady = false

        // Transform is now locked. Navigation progress may move forward, but
        // these origin/basis values are not silently recomputed.
        resetNavigationContinuity()
        navigationLastAcceptedPosition = pose.translation.copyOf()

        // The user has already walked part of the route while calibrating.
        // Start progress at the nearest recorded route coordinate instead of
        // sending them backwards to the first dense sample.
        val local = navigationLocalPosition(pose)
        activeRouteIndex = nearestNavigationPointIndex(local)

        setNavigationAlignedUi()
        setNavigationHud(
            (
                if (navigationAnchorLocalized) {
                    "Location locked: $navigationStartLabel"
                } else {
                    "Manual alignment locked"
                }
            ) +
                " • ${"%.1f".format(fit.displacementMeters)} m sample • " +
                "${(fit.straightness * 100f).toInt()}% straight.\\n" +
                "Transform locked. Follow the green target.",
        )
    }

    private fun rejectNavigationCalibration(fit: CalibrationFit) {
        resetNavigationCalibration()
        navigationOriginPosition = null
        navigationAligned = false

        mainHandler.post {
            navigationAlignButton?.apply {
                visibility = android.view.View.VISIBLE
                isEnabled = true
                alpha = 1f
                text = if (navigationAnchorLocalized) {
                    "SET QR POSITION"
                } else {
                    "SET START"
                }
            }
        }

        setNavigationArrowVisible(false)
        setNavigationHud(
            "CALIBRATION REJECTED — route sample was curved/unstable " +
                "(${"%.0f".format(fit.straightness * 100f)}% straight, " +
                "${"%.2f".format(fit.lateralRmsMeters)} m lateral RMS).\\n" +
                "Return to the exact anchor/start and try again.",
        )
        emitStatus("CALIBRATION_REJECTED")
    }

    private fun resetNavigationCalibration() {
        navigationCalibrationStart = null
        navigationCalibrationReady = false
        navigationCalibrationSamples.clear()
        navigationCalibrationPathMeters = 0f
        navigationCalibrationLastSample = null
    }

    private fun resetNavigationContinuity() {
        navigationTrackingLost = false
        navigationTrackingLostAtNanos = 0L
        navigationPositionUncertain = false
        navigationLastAcceptedPosition = null
        navigationLastAcceptedTimestampNanos = 0L
        navigationRejectedJumpCount = 0
    }

    private fun handleNavigationTrackingRecovery(
        currentPose: Pose,
        timestampNanos: Long,
    ): Boolean {
        navigationTrackingLost = false

        if (!navigationAligned) {
            navigationTrackingLostAtNanos = 0L

            if (navigationCalibrationStart != null) {
                resetNavigationCalibration()
                navigationOriginPosition = null
                mainHandler.post {
                    navigationAlignButton?.apply {
                        visibility = android.view.View.VISIBLE
                        isEnabled = true
                        alpha = 1f
                        text = if (navigationAnchorLocalized) {
                            "SET QR POSITION"
                        } else {
                            "SET START"
                        }
                    }
                }
                setNavigationHud(
                    "Tracking recovered, but calibration was interrupted. " +
                        "Return to the exact anchor/start and calibrate again.",
                )
                emitStatus("CALIBRATION_RESET")
                return false
            }

            emitTrackingState("TRACKING")
            return true
        }

        val previous = navigationLastAcceptedPosition
        if (previous == null) {
            navigationTrackingLostAtNanos = 0L
            navigationLastAcceptedPosition = currentPose.translation.copyOf()
            navigationLastAcceptedTimestampNanos = timestampNanos
            emitTrackingState("TRACKING")
            return true
        }

        val translation = currentPose.translation
        val dx = translation[0] - previous[0]
        val dz = translation[2] - previous[2]
        val jump = sqrt(dx * dx + dz * dz)

        navigationTrackingLostAtNanos = 0L

        if (jump > navigationRecoveryMaxJumpMeters) {
            navigationPositionUncertain = true
            showNavigationPositionUncertain(
                "ARCore recovered ${"%.1f".format(jump)} m away from the last " +
                    "trusted pose. The venue transform was NOT moved.",
            )
            emitStatus("POSITION_UNCERTAIN")
            return false
        }

        navigationLastAcceptedPosition = translation.copyOf()
        navigationLastAcceptedTimestampNanos = timestampNanos
        navigationRejectedJumpCount = 0
        emitTrackingState("TRACKING")
        setNavigationHud(
            "Tracking recovered. Transform stayed locked; continue walking.",
        )
        return true
    }

    private fun acceptNavigationPose(
        currentPose: Pose,
        timestampNanos: Long,
    ): Boolean {
        val previous = navigationLastAcceptedPosition
        if (previous == null || navigationLastAcceptedTimestampNanos == 0L) {
            navigationLastAcceptedPosition = currentPose.translation.copyOf()
            navigationLastAcceptedTimestampNanos = timestampNanos
            navigationRejectedJumpCount = 0
            return true
        }

        val dtSeconds =
            ((timestampNanos - navigationLastAcceptedTimestampNanos).coerceAtLeast(1L))
                .toFloat() / 1_000_000_000f

        val translation = currentPose.translation
        val dx = translation[0] - previous[0]
        val dz = translation[2] - previous[2]
        val jump = sqrt(dx * dx + dz * dz)

        val allowed =
            (navigationJumpBaseMeters +
                navigationMaxPlausibleSpeedMps * dtSeconds)
                .coerceAtMost(2.75f)

        if (jump > allowed) {
            navigationRejectedJumpCount++

            setNavigationArrowVisible(false)
            setNavigationHud(
                "Checking AR position… impossible ${"%.1f".format(jump)} m " +
                    "pose jump rejected (${navigationRejectedJumpCount}/3).",
            )

            if (navigationRejectedJumpCount >= 3) {
                navigationPositionUncertain = true
                showNavigationPositionUncertain(
                    "Repeated ARCore pose jumps were rejected. The route " +
                        "transform was kept locked instead of moving the venue.",
                )
                emitStatus("POSITION_UNCERTAIN")
            }
            return false
        }

        navigationRejectedJumpCount = 0
        navigationLastAcceptedPosition = translation.copyOf()
        navigationLastAcceptedTimestampNanos = timestampNanos
        return true
    }

    private fun showNavigationPositionUncertain(
        detail: String =
            "AR position is no longer trustworthy. Scan a known location QR " +
                "before continuing.",
    ) {
        setNavigationArrowVisible(false)
        mainHandler.post {
            navigationStatusText?.text =
                "POSITION UNCERTAIN — STOP WALKING\\n$detail\\n" +
                    "Tap SCAN LOCATION to re-localize."
            navigationReanchorButton?.visibility = android.view.View.VISIBLE
        }
    }

    private fun nearestNavigationPointIndex(local: LocalPosition): Int {
        if (navigationPoints.size <= 1) return 1

        var bestIndex = 1
        var bestDistance = Float.MAX_VALUE

        for (i in 1 until navigationPoints.size) {
            val point = navigationPoints[i]
            val dx = point.rightMeters - local.right
            val df = point.forwardMeters - local.forward
            val distance = dx * dx + df * df

            if (distance < bestDistance) {
                bestDistance = distance
                bestIndex = i
            }
        }

        return bestIndex
    }

    private fun clearNavigationFrame() {
        navigationOriginPosition = null
        navigationForwardX = 0f
        navigationForwardZ = -1f
        navigationRightX = 1f
        navigationRightZ = 0f
        resetNavigationCalibration()
        resetNavigationContinuity()
    }

    private fun trackingLocalPosition(pose: Pose): LocalPosition {
        val origin = trackingOriginPosition ?: pose.translation
        return localPosition(
            pose = pose,
            origin = origin,
            forwardX = trackingForwardX,
            forwardZ = trackingForwardZ,
            rightX = trackingRightX,
            rightZ = trackingRightZ,
        )
    }

    private fun navigationLocalPosition(pose: Pose): LocalPosition {
        val origin = navigationOriginPosition ?: pose.translation
        return localPosition(
            pose = pose,
            origin = origin,
            forwardX = navigationForwardX,
            forwardZ = navigationForwardZ,
            rightX = navigationRightX,
            rightZ = navigationRightZ,
        )
    }

    private fun localPosition(
        pose: Pose,
        origin: FloatArray,
        forwardX: Float,
        forwardZ: Float,
        rightX: Float,
        rightZ: Float,
    ): LocalPosition {
        val translation = pose.translation
        val dx = translation[0] - origin[0]
        val dy = translation[1] - origin[1]
        val dz = translation[2] - origin[2]

        return LocalPosition(
            right = dx * rightX + dz * rightZ,
            up = dy,
            forward = dx * forwardX + dz * forwardZ,
        )
    }

    private fun relativeHeadingRadians(
        pose: Pose,
        originForwardX: Float,
        originForwardZ: Float,
        originRightX: Float,
        originRightZ: Float,
    ): Float {
        val currentForward = horizontalForward(pose)
        val forwardComponent =
            currentForward[0] * originForwardX +
                currentForward[2] * originForwardZ
        val rightComponent =
            currentForward[0] * originRightX +
                currentForward[2] * originRightZ

        return atan2(rightComponent, forwardComponent)
    }

    private fun emitHorizontalPose(
        currentPose: Pose,
        local: LocalPosition,
        timestampNanos: Long,
        originForwardX: Float,
        originForwardZ: Float,
        originRightX: Float,
        originRightZ: Float,
    ) {
        if (timestampNanos - lastEmitNanos < 50_000_000L) return
        lastEmitNanos = timestampNanos

        val yaw = relativeHeadingRadians(
            pose = currentPose,
            originForwardX = originForwardX,
            originForwardZ = originForwardZ,
            originRightX = originRightX,
            originRightZ = originRightZ,
        )

        // Emit a yaw-only quaternion. Flutter can visualize facing without
        // inheriting camera pitch/roll, while position stays gravity-horizontal.
        val half = yaw / 2f
        val qy = sin(half)
        val qw = cos(half)
        val horizontal = sqrt(
            local.right * local.right +
                local.forward * local.forward,
        )

        emit(
            mapOf(
                "type" to "pose",
                "tracking" to "TRACKING",
                "timestamp_ns" to timestampNanos,
                "x" to local.right.toDouble(),
                "y" to local.up.toDouble(),
                "z" to (-local.forward).toDouble(),
                "forward" to local.forward.toDouble(),
                "horizontal_distance" to horizontal.toDouble(),
                "qx" to 0.0,
                "qy" to qy.toDouble(),
                "qz" to 0.0,
                "qw" to qw.toDouble(),
            ),
        )
    }

    private fun updateNavigationProgress(
        currentPose: Pose,
        local: LocalPosition,
        worldPoints: List<FloatArray>,
        timestampNanos: Long,
    ) {
        if (navigationPoints.isEmpty() || worldPoints.isEmpty()) return

        while (activeRouteIndex < navigationPoints.size) {
            val target = navigationPoints[activeRouteIndex]
            val dx = target.rightMeters - local.right
            val df = target.forwardMeters - local.forward
            val distance = sqrt(dx * dx + df * df)

            if (distance > 1.15f) break
            activeRouteIndex++
        }

        if (activeRouteIndex >= navigationPoints.size) {
            if (!navigationArrivalShown) {
                navigationArrivalShown = true
                setNavigationArrivalUi()
                emitStatus("ARRIVED")
            }
            return
        }

        val targetPoint = worldPoints[activeRouteIndex]
        val targetAngle = targetAngleDegrees(
            cameraPose = currentPose,
            targetPoint = targetPoint,
        )
        setNavigationArrow(targetAngle)

        if (timestampNanos - lastHudNanos < 160_000_000L) return
        lastHudNanos = timestampNanos

        val target = navigationPoints[activeRouteIndex]
        val dx = target.rightMeters - local.right
        val df = target.forwardMeters - local.forward
        val nextDistance = sqrt(dx * dx + df * df)

        var remaining = nextDistance
        for (i in activeRouteIndex until navigationPoints.lastIndex) {
            val a = navigationPoints[i]
            val b = navigationPoints[i + 1]
            val sx = b.rightMeters - a.rightMeters
            val sf = b.forwardMeters - a.forwardMeters
            remaining += sqrt(sx * sx + sf * sf)
        }

        val nextLabel = if (target.semantic && target.label != "Recorded path") {
            target.label
        } else {
            "next route point"
        }

        val direction = when {
            targetAngle > 150f || targetAngle < -150f -> "behind"
            targetAngle > 18f -> "${targetAngle.toInt()}° right"
            targetAngle < -18f -> "${(-targetAngle).toInt()}° left"
            else -> "ahead"
        }

        setNavigationHud(
            "Next: $nextLabel • ${"%.1f".format(nextDistance)} m • $direction\n" +
                "Remaining: ${"%.1f".format(remaining)} m",
        )
    }

    private fun targetAngleDegrees(
        cameraPose: Pose,
        targetPoint: FloatArray,
    ): Float {
        val cameraPosition = cameraPose.translation
        val dx = targetPoint[0] - cameraPosition[0]
        val dz = targetPoint[2] - cameraPosition[2]
        val targetLength = sqrt(dx * dx + dz * dz)
        if (targetLength < 0.0001f) return 0f

        val tx = dx / targetLength
        val tz = dz / targetLength

        val cameraForward = horizontalForward(cameraPose)
        val fx = cameraForward[0]
        val fz = cameraForward[2]
        val rx = -fz
        val rz = fx

        val forwardComponent = tx * fx + tz * fz
        val rightComponent = tx * rx + tz * rz

        return (
            atan2(rightComponent, forwardComponent) *
                180.0 /
                Math.PI
            ).toFloat()
    }

    private fun routeWorldPoints(): List<FloatArray> {
        val origin = navigationOriginPosition ?: return emptyList()

        // Breadcrumbs sit on one horizontal plane below the phone's alignment
        // height. Camera pitch/roll can change freely without tilting the route.
        val routeY = origin[1] - 1.10f

        return navigationPoints.map { point ->
            floatArrayOf(
                origin[0] +
                    navigationRightX * point.rightMeters +
                    navigationForwardX * point.forwardMeters,
                routeY,
                origin[2] +
                    navigationRightZ * point.rightMeters +
                    navigationForwardZ * point.forwardMeters,
            )
        }
    }

    private fun createNavigationOverlay(glView: GLSurfaceView) {
        val overlay = FrameLayout(activity).apply {
            setBackgroundColor(Color.BLACK)
        }

        overlay.addView(
            glView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        val topCard = TextView(activity).apply {
            text = "AR GUIDE\n${navigationPoints.firstOrNull()?.label ?: "Start"} → $navigationDestination"
            setTextColor(Color.WHITE)
            textSize = 17f
            setPadding(dp(16), dp(12), dp(16), dp(12))
            background = roundedBackground(0xB8000000.toInt(), dp(18).toFloat())
        }
        overlay.addView(
            topCard,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            ).apply {
                gravity = Gravity.TOP
                setMargins(dp(72), dp(38), dp(24), 0)
            },
        )

        val targetArrow = TextView(activity).apply {
            text = "▲"
            textSize = 48f
            gravity = Gravity.CENTER
            setTextColor(0xFF3DDC97.toInt())
            alpha = 0f
            background = roundedBackground(
                0x99000000.toInt(),
                dp(36).toFloat(),
            )
        }
        navigationArrowText = targetArrow
        overlay.addView(
            targetArrow,
            FrameLayout.LayoutParams(dp(82), dp(82)).apply {
                gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                setMargins(0, dp(154), 0, 0)
            },
        )

        val closeButton = Button(activity).apply {
            text = "×"
            textSize = 24f
            setTextColor(Color.WHITE)
            background = roundedBackground(0xB8000000.toInt(), dp(28).toFloat())
            setOnClickListener {
                emitStatus("NAV_CLOSED")
                mainHandler.post {
                    onNavigationClosed?.invoke() ?: stop()
                }
            }
        }
        overlay.addView(
            closeButton,
            FrameLayout.LayoutParams(dp(52), dp(52)).apply {
                gravity = Gravity.TOP or Gravity.START
                setMargins(dp(14), dp(38), 0, 0)
            },
        )

        val statusText = TextView(activity).apply {
            text = if (navigationAnchorLocalized) {
                "Location confirmed: $navigationStartLabel\n" +
                    "Stay at the physical QR marker, then set its AR position."
            } else {
                "Manual preview: stand exactly at the selected mapped start."
            }
            setTextColor(Color.WHITE)
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(dp(14), dp(10), dp(14), dp(10))
            background = roundedBackground(0xB8000000.toInt(), dp(18).toFloat())
        }
        navigationStatusText = statusText
        overlay.addView(
            statusText,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            ).apply {
                gravity = Gravity.BOTTOM
                setMargins(dp(24), 0, dp(24), dp(116))
            },
        )

        val controls = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }

        val align = Button(activity).apply {
            text = if (navigationAnchorLocalized) {
                "SET QR POSITION"
            } else {
                "SET START"
            }
            textSize = 14f
            setTextColor(Color.BLACK)
            background = roundedBackground(
                0xFF72A7FF.toInt(),
                dp(22).toFloat(),
            )
            setOnClickListener {
                alignmentRequested = true
                if (navigationCalibrationStart == null) {
                    setNavigationHud(
                        if (navigationAnchorLocalized) {
                            "Fixing $navigationStartLabel at this physical QR position..."
                        } else {
                            "Fixing the manual start position here..."
                        },
                    )
                } else {
                    setNavigationHud("Validating calibration trajectory and locking route transform...")
                }
            }
        }
        navigationAlignButton = align

        val reanchor = Button(activity).apply {
            text = "SCAN LOCATION"
            textSize = 13f
            setTextColor(Color.BLACK)
            visibility = android.view.View.GONE
            background = roundedBackground(
                0xFF3DDC97.toInt(),
                dp(22).toFloat(),
            )
            setOnClickListener {
                setNavigationHud("Opening location QR scanner...")
                emitStatus("REANCHOR_REQUEST")
            }
        }
        navigationReanchorButton = reanchor

        val exit = Button(activity).apply {
            text = "EXIT"
            textSize = 14f
            setTextColor(Color.WHITE)
            background = roundedBackground(
                0xB8000000.toInt(),
                dp(22).toFloat(),
            )
            setOnClickListener {
                emitStatus("NAV_CLOSED")
                mainHandler.post {
                    onNavigationClosed?.invoke() ?: stop()
                }
            }
        }
        navigationExitButton = exit

        controls.addView(
            align,
            LinearLayout.LayoutParams(0, dp(56), 2f).apply {
                marginEnd = dp(8)
            },
        )
        controls.addView(
            reanchor,
            LinearLayout.LayoutParams(0, dp(56), 2f).apply {
                marginEnd = dp(8)
            },
        )
        controls.addView(
            exit,
            LinearLayout.LayoutParams(0, dp(56), 1f),
        )

        overlay.addView(
            controls,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                dp(56),
            ).apply {
                gravity = Gravity.BOTTOM
                setMargins(dp(24), 0, dp(24), dp(42))
            },
        )

        activity.addContentView(
            overlay,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        navigationOverlay = overlay
    }

    private fun setNavigationAlignedUi() {
        mainHandler.post {
            navigationAlignButton?.apply {
                visibility = android.view.View.GONE
                isEnabled = true
                alpha = 1f
            }
            navigationReanchorButton?.visibility = android.view.View.VISIBLE
        }
    }

    private fun setNavigationArrivalUi() {
        mainHandler.post {
            navigationArrowText?.apply {
                alpha = 1f
                rotation = 0f
                text = "✓"
                textSize = 52f
                setTextColor(0xFF3DDC97.toInt())
            }
            navigationStatusText?.text =
                "DESTINATION REACHED\n$navigationDestination"
            navigationAlignButton?.visibility = android.view.View.GONE
            navigationReanchorButton?.visibility = android.view.View.GONE
            navigationExitButton?.text = "DONE"
        }
    }

    private fun setNavigationArrow(angleDegrees: Float) {
        mainHandler.post {
            navigationArrowText?.apply {
                text = "▲"
                textSize = 48f
                setTextColor(0xFF3DDC97.toInt())
                alpha = 1f
                rotation = angleDegrees
            }
        }
    }

    private fun setNavigationArrowVisible(visible: Boolean) {
        mainHandler.post {
            navigationArrowText?.alpha = if (visible) 1f else 0f
        }
    }

    private fun setNavigationHud(text: String) {
        mainHandler.post {
            navigationStatusText?.text = text
        }
    }

    private fun roundedBackground(color: Int, radius: Float): GradientDrawable {
        return GradientDrawable().apply {
            setColor(color)
            cornerRadius = radius
        }
    }

    private fun dp(value: Int): Int {
        return (value * activity.resources.displayMetrics.density).toInt()
    }

    private fun trackingFailureMessage(reason: String?): String? {
        return when (reason) {
            "INSUFFICIENT_LIGHT" ->
                "Tracking paused: the scene is too dark. Point the camera at a brighter area."
            "EXCESSIVE_MOTION" ->
                "Tracking paused: move the phone more slowly."
            "INSUFFICIENT_FEATURES" ->
                "Tracking paused: aim at textured surfaces, edges, signs, or objects."
            "CAMERA_UNAVAILABLE" ->
                "Tracking paused: camera unavailable."
            "BAD_STATE" ->
                "Tracking paused: ARCore entered a bad tracking state."
            else -> null
        }
    }

    private fun emitTrackingState(
        state: String,
        reason: String? = null,
    ) {
        if (
            state == lastCameraTrackingState &&
            reason == lastCameraTrackingReason
        ) {
            return
        }

        lastCameraTrackingState = state
        lastCameraTrackingReason = reason

        val payload = mutableMapOf<String, Any>(
            "type" to "status",
            "tracking" to state,
        )

        if (reason != null && reason != "NONE") {
            payload["code"] = reason

            val message = trackingFailureMessage(reason)
            if (message != null) {
                payload["message"] = message
            }
        }

        emit(payload)
    }

    private fun emitStatus(state: String) {
        emit(
            mapOf(
                "type" to "status",
                "tracking" to state,
            ),
        )
    }

    private fun emitError(code: String, message: String?) {
        emit(
            mapOf(
                "type" to "error",
                "tracking" to "ERROR",
                "code" to code,
                "message" to (message ?: "Unknown ARCore error"),
            ),
        )
    }

    private fun emit(payload: Map<String, Any>) {
        mainHandler.post {
            poseSinkProvider()?.success(payload)
        }
    }

    private fun cleanupFailedStart() {
        val oldOverlay = navigationOverlay
        val oldView = surfaceView
        navigationOverlay = null
        navigationStatusText = null
        navigationArrowText = null
        navigationAlignButton = null
        navigationReanchorButton = null
        navigationExitButton = null
        surfaceView = null

        if (oldOverlay != null || oldView != null) {
            mainHandler.post {
                (oldOverlay?.parent as? ViewGroup)?.removeView(oldOverlay)
                if (oldOverlay == null) {
                    (oldView?.parent as? ViewGroup)?.removeView(oldView)
                }
            }
        }

        try {
            session?.close()
        } catch (_: Exception) {
        }

        session = null
        started = false
        sessionResumed = false
        clearTrackingOrigin()
        clearNavigationFrame()
        latestCameraPose = null
        cameraTextureId = 0
        lastEmitNanos = 0L
        lastHudNanos = 0L
        navigationMode = false
        navigationAligned = false
        alignmentRequested = false
        resetNavigationCalibration()
        resetNavigationContinuity()
        navigationArrivalShown = false
        navigationPoints = emptyList()
    }
}
