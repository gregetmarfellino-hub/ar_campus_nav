package com.example.ar_campus_nav

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
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
import com.google.ar.core.Anchor
import com.google.ar.core.ArCoreApk
import com.google.ar.core.AugmentedImage
import com.google.ar.core.AugmentedImageDatabase
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
    private val qrPlacementRenderer = ArQrPlacementPreviewRenderer()

    private var session: Session? = null
    private var surfaceView: GLSurfaceView? = null
    private var navigationOverlay: FrameLayout? = null
    private var navigationStatusText: TextView? = null
    private var navigationArrowText: TextView? = null
    private var navigationAlignButton: Button? = null
    private var navigationReanchorButton: Button? = null
    private var navigationExitButton: Button? = null

    // Free-floating visual QR placement used by the spatial mapper. The QR is
    // a real 3D AR billboard, not a wall/plane hit. While placement is open it
    // floats a configurable distance along the live camera ray; pressing PLACE
    // freezes that exact metric pose into the mapping-local frame.
    private var qrPlacementOverlay: FrameLayout? = null
    private var qrPlacementStatusText: TextView? = null
    private var qrPlacementDistanceText: TextView? = null
    private var qrPlacementButton: Button? = null
    @Volatile private var qrPlacementMode = false
    @Volatile private var qrPlacementRequested = false
    @Volatile private var qrPlacementDistanceMeters = 1.0f
    private var qrPlacementTrackingReady = false
    private var qrPlacementBitmap: Bitmap? = null
    private var qrPlacementWidthMeters = 0.16f
    private var qrPlacementCompletion: ((Map<String, Any>?) -> Unit)? = null

    // Persistent start portal. Mapping hosts one Cloud Anchor at the portal
    // pose; navigation resolves the saved ID in a fresh ARCore session.
    private var persistentPortalMappingMode = false
    private var persistentPortalLocalDevMode = false
    private var persistentPortalHosting = false
    private var persistentPortalHostAnchor: Anchor? = null
    private var persistentPortalHostFuture: com.google.ar.core.HostCloudAnchorFuture? = null
    private var persistentPortalLabel = "Start portal"
    private var navigationCloudAnchorId: String? = null
    private var navigationLocalDevPortal = false
    private var navigationResolveFuture: com.google.ar.core.ResolveCloudAnchorFuture? = null
    private var navigationCloudResolveAttempted = false
    private var navigationPortalActivated = false
    private var navigationPortalFocusFrames = 0
    private val navigationPortalFocusFramesRequired = 12

    // Physical start QR localization for mapping. The image database is loaded
    // before the ARCore session starts, then the mapper camera waits for this
    // real-world QR and uses its measured center + outward normal as the
    // persistent mapping frame.
    private var mappingVisualAnchorBitmap: Bitmap? = null
    private var mappingVisualAnchorWidthMeters = 0f
    private var mappingVisualAnchorLabel = ""
    private var mappingVisualAnchorEnabled = false
    private var mappingVisualOverlay: FrameLayout? = null
    private var mappingVisualStatusText: TextView? = null
    private var mappingVisualLastHudText: String? = null
    private var mappingVisualSampleCount = 0
    private var mappingVisualPositionX = 0f
    private var mappingVisualPositionY = 0f
    private var mappingVisualPositionZ = 0f
    private var mappingVisualForwardX = 0f
    private var mappingVisualForwardZ = 0f
    private val mappingVisualSamplesRequired = 6
    private val mappingVisualImageName = "ar_mapping_start_qr"

    private var cameraTextureId: Int = 0

    // Tracking/mapping origin: gravity-horizontal frame.
    // This intentionally ignores the phone's pitch/roll at startup.
    private var trackingOriginPosition: FloatArray? = null
    private var trackingForwardX = 0f
    private var trackingForwardZ = -1f
    private var trackingRightX = 1f
    private var trackingRightZ = 0f

    // Navigation alignment frame. The physical origin is a real ARCore
    // Anchor; route basis vectors live in that anchor-local X/Z plane.
    private var navigationWorldAnchor: Anchor? = null
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

    // Visual QR localization. Flutter supplies the exact QR bitmap shown to
    // users plus its physical printed width. ARCore detects that same planar
    // image and gives us a metric 6DoF pose.
    private var navigationVisualAnchorBitmap: Bitmap? = null
    private var navigationVisualAnchorWidthMeters = 0f
    private var navigationVisualAnchorLabel = ""
    private var navigationVisualRouteOffsetDegrees = 0f
    private var navigationVisualAnchorEnabled = false
    private var navigationVisualSetupWarning: String? = null
    private var navigationVisualSampleCount = 0
    private var navigationVisualPositionX = 0f
    private var navigationVisualPositionZ = 0f
    private var navigationVisualForwardX = 0f
    private var navigationVisualForwardZ = 0f
    private val navigationVisualSamplesRequired = 6
    private val navigationVisualImageName = "ar_nav_visual_anchor"

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

    private fun isLocalDevPortalId(value: String?): Boolean =
        value?.startsWith("localdev:") == true

    private fun hasArCoreCloudApiKey(): Boolean {
        return try {
            val info = activity.packageManager.getApplicationInfo(
                activity.packageName,
                android.content.pm.PackageManager.GET_META_DATA,
            )
            val key = info.metaData
                ?.getString("com.google.android.ar.API_KEY")
                ?.trim()
            !key.isNullOrEmpty() && key != "YOUR_ARCORE_API_KEY_HERE"
        } catch (_: Exception) {
            false
        }
    }

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
        clearVisualAnchorConfiguration()
        clearMappingVisualAnchorConfiguration()
        return startSession()
    }

    fun startPersistentPortalMapping(
        qrPng: ByteArray,
        widthMeters: Float,
        label: String,
    ): String {
        navigationMode = false
        clearVisualAnchorConfiguration()
        clearMappingVisualAnchorConfiguration()
        clearPersistentPortalState()
        if (!hasArCoreCloudApiKey()) {
            return "CLOUD_ANCHOR_NOT_CONFIGURED"
        }
        persistentPortalLocalDevMode = false

        val bitmap = BitmapFactory.decodeByteArray(qrPng, 0, qrPng.size)
            ?: return "PORTAL_QR_DECODE_FAILED"
        if (widthMeters <= 0f) {
            bitmap.recycle()
            return "PORTAL_QR_SIZE_INVALID"
        }

        qrPlacementBitmap?.recycle()
        qrPlacementBitmap = bitmap
        qrPlacementWidthMeters = widthMeters
        qrPlacementDistanceMeters = 1.0f
        qrPlacementCompletion = null
        qrPlacementRequested = false
        qrPlacementTrackingReady = false
        qrPlacementMode = true
        persistentPortalMappingMode = true
        persistentPortalHosting = false
        persistentPortalLabel = label
        qrPlacementRenderer.setBitmap(bitmap)

        return startSession()
    }

    fun startMappingWithVisualAnchor(
        visualAnchorPng: ByteArray,
        visualAnchorWidthMeters: Float,
        visualAnchorLabel: String,
    ): String {
        navigationMode = false
        clearVisualAnchorConfiguration()
        clearMappingVisualAnchorConfiguration()

        val bitmap = BitmapFactory.decodeByteArray(
            visualAnchorPng,
            0,
            visualAnchorPng.size,
        ) ?: return "MAPPING_QR_DECODE_FAILED"

        mappingVisualAnchorBitmap = bitmap
        mappingVisualAnchorWidthMeters = visualAnchorWidthMeters
        mappingVisualAnchorLabel = visualAnchorLabel
        mappingVisualAnchorEnabled = true
        resetMappingVisualSamples()

        return startSession()
    }

    fun startNavigation(
        destination: String,
        points: List<RoutePoint>,
        startLabel: String = "Route start",
        anchorLocalized: Boolean = false,
        visualAnchorPng: ByteArray? = null,
        visualAnchorWidthMeters: Float? = null,
        visualAnchorLabel: String? = null,
        visualAnchorRouteOffsetDegrees: Float? = null,
        cloudAnchorId: String? = null,
    ): String {
        if (points.size < 2) return "ROUTE_TOO_SHORT"

        navigationMode = true
        navigationDestination = destination
        navigationStartLabel = startLabel
        navigationAnchorLocalized = anchorLocalized
        navigationPoints = points
        navigationCloudAnchorId = cloudAnchorId?.takeIf { it.isNotBlank() }
        navigationLocalDevPortal = isLocalDevPortalId(navigationCloudAnchorId)
        navigationResolveFuture?.cancel()
        navigationResolveFuture = null
        navigationCloudResolveAttempted = false
        navigationPortalFocusFrames = 0
        navigationPortalActivated = navigationCloudAnchorId == null

        if (navigationCloudAnchorId != null) {
            clearVisualAnchorConfiguration()
            configurePersistentPortalPreview(
                png = visualAnchorPng,
                widthMeters = visualAnchorWidthMeters,
                label = visualAnchorLabel,
            )
        } else {
            configureVisualAnchor(
                png = visualAnchorPng,
                widthMeters = visualAnchorWidthMeters,
                label = visualAnchorLabel,
                routeOffsetDegrees = visualAnchorRouteOffsetDegrees,
            )
        }
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
                if ((persistentPortalMappingMode &&
                        !persistentPortalLocalDevMode) ||
                    (!navigationCloudAnchorId.isNullOrBlank() &&
                        !navigationLocalDevPortal)
                ) {
                    cloudAnchorMode = Config.CloudAnchorMode.ENABLED
                }
            }
            configureVisualImageDatabase(newSession, config)
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
            } else if (qrPlacementMode) {
                createQrPlacementOverlay(glView)
            } else if (mappingVisualAnchorEnabled) {
                createMappingVisualOverlay(glView)
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

    fun beginVisualQrPlacement(
        qrPng: ByteArray,
        widthMeters: Float,
        onComplete: (Map<String, Any>?) -> Unit,
    ): String? {
        if (!started || session == null || surfaceView == null) {
            return "ARCore spatial mapping is not running."
        }
        if (navigationMode) {
            return "QR placement is only available while mapping."
        }
        if (qrPlacementMode) {
            return "QR placement is already open."
        }
        if (trackingOriginPosition == null) {
            return "Mapping origin is not ready yet. Wait for TRACKING, then try again."
        }

        val bitmap = BitmapFactory.decodeByteArray(qrPng, 0, qrPng.size)
            ?: return "The QR preview image could not be decoded."
        if (widthMeters <= 0f) {
            bitmap.recycle()
            return "QR width must be positive."
        }

        qrPlacementBitmap?.recycle()
        qrPlacementBitmap = bitmap
        qrPlacementWidthMeters = widthMeters
        qrPlacementDistanceMeters = 1.0f
        qrPlacementCompletion = onComplete
        qrPlacementRequested = false
        qrPlacementTrackingReady = false
        qrPlacementMode = true
        qrPlacementRenderer.setBitmap(bitmap)

        mainHandler.post { createQrPlacementOverlay() }
        return null
    }

    private fun createQrPlacementOverlay(
        suppliedView: GLSurfaceView? = surfaceView,
    ) {
        val glView = suppliedView ?: run {
            finishQrPlacement(null)
            return
        }

        (qrPlacementOverlay?.parent as? ViewGroup)?.removeView(qrPlacementOverlay)

        val overlay = FrameLayout(activity)

        val existingParent = glView.parent as? ViewGroup
        if (existingParent == null) {
            overlay.addView(
                glView,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT,
                ),
            )
        } else {
            glView.layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            )
            glView.bringToFront()
        }

        val status = TextView(activity).apply {
            text = if (persistentPortalMappingMode) {
                "PLACE START PORTAL\nMove/aim the phone to position the floating QR start portal. " +
                    "Scan the entrance area slowly until persistence quality is ready."
            } else {
                "PLACE QR IN 3D\nMove/aim the phone to position the floating QR. " +
                    "It does not need a wall or detected plane."
            }
            setTextColor(Color.WHITE)
            textSize = 16f
            gravity = Gravity.CENTER
            setPadding(dp(16), dp(12), dp(16), dp(12))
            background = roundedBackground(0xC0000000.toInt(), dp(18).toFloat())
        }
        qrPlacementStatusText = status
        overlay.addView(
            status,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            ).apply {
                gravity = Gravity.TOP
                setMargins(dp(20), dp(36), dp(20), 0)
            },
        )

        val distanceRow = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            background = roundedBackground(0xB8000000.toInt(), dp(22).toFloat())
            setPadding(dp(8), dp(4), dp(8), dp(4))
        }

        val nearer = Button(activity).apply {
            text = "−"
            textSize = 22f
            setTextColor(Color.WHITE)
            background = roundedBackground(0x33000000, dp(18).toFloat())
            setOnClickListener { adjustQrPlacementDistance(-0.20f) }
        }
        val distance = TextView(activity).apply {
            text = "1.0 m"
            textSize = 16f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
        }
        qrPlacementDistanceText = distance
        val farther = Button(activity).apply {
            text = "+"
            textSize = 20f
            setTextColor(Color.WHITE)
            background = roundedBackground(0x33000000, dp(18).toFloat())
            setOnClickListener { adjustQrPlacementDistance(0.20f) }
        }

        distanceRow.addView(
            nearer,
            LinearLayout.LayoutParams(dp(58), dp(48)),
        )
        distanceRow.addView(
            distance,
            LinearLayout.LayoutParams(dp(110), dp(48)),
        )
        distanceRow.addView(
            farther,
            LinearLayout.LayoutParams(dp(58), dp(48)),
        )

        overlay.addView(
            distanceRow,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                dp(56),
            ).apply {
                gravity = Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM
                bottomMargin = dp(118)
            },
        )

        val controls = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }

        val place = Button(activity).apply {
            text = if (persistentPortalMappingMode) {
                "LOCK START PORTAL"
            } else {
                "PLACE QR HERE"
            }
            textSize = 15f
            if (persistentPortalMappingMode) {
                isEnabled = false
                alpha = 0.45f
            }
            setTextColor(Color.BLACK)
            background = roundedBackground(0xFF3DDC97.toInt(), dp(24).toFloat())
            setOnClickListener {
                qrPlacementRequested = true
                qrPlacementStatusText?.text = "Saving this exact 3D QR pose..."
            }
        }
        qrPlacementButton = place

        val cancel = Button(activity).apply {
            text = "CANCEL"
            textSize = 14f
            setTextColor(Color.WHITE)
            background = roundedBackground(0xC0000000.toInt(), dp(24).toFloat())
            setOnClickListener {
                if (persistentPortalMappingMode) {
                    emitStatus("PERSISTENT_PORTAL_CANCELLED")
                    finishQrPlacement(null)
                    mainHandler.post { stop() }
                } else {
                    finishQrPlacement(null)
                }
            }
        }

        controls.addView(
            place,
            LinearLayout.LayoutParams(0, dp(58), 2f).apply {
                marginEnd = dp(10)
            },
        )
        controls.addView(
            cancel,
            LinearLayout.LayoutParams(0, dp(58), 1f),
        )

        overlay.addView(
            controls,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                dp(58),
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
        qrPlacementOverlay = overlay
    }

    private fun adjustQrPlacementDistance(deltaMeters: Float) {
        qrPlacementDistanceMeters =
            (qrPlacementDistanceMeters + deltaMeters).coerceIn(0.40f, 3.00f)
        qrPlacementDistanceText?.text =
            String.format(java.util.Locale.US, "%.1f m", qrPlacementDistanceMeters)
    }

    private fun handleQrPlacementFrame(
        currentPose: Pose,
        camera: com.google.ar.core.Camera,
    ) {
        if (persistentPortalHosting) {
            val hostedAnchor = persistentPortalHostAnchor
            if (hostedAnchor != null &&
                hostedAnchor.trackingState == TrackingState.TRACKING
            ) {
                val pose = hostedAnchor.pose
                qrPlacementRenderer.draw(
                    camera = camera,
                    center = pose.translation,
                    rightAxis = pose.getTransformedAxis(0, 1f),
                    upAxis = pose.getTransformedAxis(1, 1f),
                    sizeMeters = qrPlacementWidthMeters,
                )
            }
            return
        }

        val cameraForward = currentPose.getTransformedAxis(2, -1f)
        val cameraPosition = currentPose.translation
        val distance = qrPlacementDistanceMeters

        val center = floatArrayOf(
            cameraPosition[0] + cameraForward[0] * distance,
            cameraPosition[1] + cameraForward[1] * distance,
            cameraPosition[2] + cameraForward[2] * distance,
        )

        val horizontal = horizontalForward(currentPose)
        val outwardX = -horizontal[0]
        val outwardZ = -horizontal[2]
        val rightAxis = floatArrayOf(outwardZ, 0f, -outwardX)
        val upAxis = floatArrayOf(0f, 1f, 0f)
        val targetPose = horizontalPoseFromForward(
            position = center,
            forwardX = horizontal[0],
            forwardZ = horizontal[2],
        )

        qrPlacementRenderer.draw(
            camera = camera,
            center = center,
            rightAxis = rightAxis,
            upAxis = upAxis,
            sizeMeters = qrPlacementWidthMeters,
        )

        if (persistentPortalMappingMode) {
            updatePersistentPortalQuality(currentPose)
        }

        if (!qrPlacementRequested) return
        qrPlacementRequested = false

        if (persistentPortalMappingMode) {
            val activeSession = session ?: run {
                setPersistentPortalStatus("ARCore session is unavailable. Try again.")
                return
            }
            if (!persistentPortalLocalDevMode) {
                val quality =
                    activeSession.estimateFeatureMapQualityForHosting(currentPose)
                if (quality == Session.FeatureMapQuality.INSUFFICIENT) {
                    setPersistentPortalStatus(
                        "NOT ENOUGH VISUAL DETAIL YET — slowly scan the entrance area around the portal.",
                    )
                    return
                }
            }

            trackingOriginPosition = center.copyOf()
            trackingForwardX = horizontal[0]
            trackingForwardZ = horizontal[2]
            trackingRightX = -trackingForwardZ
            trackingRightZ = trackingForwardX

            hostPersistentStartPortal(
                activeSession = activeSession,
                targetPose = targetPose,
            )
            return
        }

        val origin = trackingOriginPosition ?: run {
            mainHandler.post {
                qrPlacementStatusText?.text =
                    "Mapping origin is unavailable. Cancel and restart mapping."
            }
            return
        }

        val local = localPosition(
            pose = targetPose,
            origin = origin,
            forwardX = trackingForwardX,
            forwardZ = trackingForwardZ,
            rightX = trackingRightX,
            rightZ = trackingRightZ,
        )

        val forwardComponent =
            outwardX * trackingForwardX + outwardZ * trackingForwardZ
        val rightComponent =
            outwardX * trackingRightX + outwardZ * trackingRightZ

        var facingDegrees = (
            atan2(rightComponent, forwardComponent) *
                180.0 /
                Math.PI
            ).toFloat()
        facingDegrees %= 360f
        if (facingDegrees < 0f) facingDegrees += 360f

        finishQrPlacement(
            mapOf(
                "right_m" to local.right.toDouble(),
                "forward_m" to local.forward.toDouble(),
                "up_m" to local.up.toDouble(),
                "facing_deg" to facingDegrees.toDouble(),
            ),
        )
    }

    private fun updatePersistentPortalQuality(cameraPose: Pose) {
        val activeSession = session ?: return

        if (persistentPortalLocalDevMode) {
            mainHandler.post {
                qrPlacementButton?.apply {
                    isEnabled = true
                    alpha = 1f
                }
                qrPlacementStatusText?.text =
                    "LOCAL DEV MODE — position the QR portal, then tap LOCK START PORTAL. " +
                        "This tests the UX but not real-world cross-session persistence."
            }
            return
        }

        val quality = try {
            activeSession.estimateFeatureMapQualityForHosting(cameraPose)
        } catch (_: Exception) {
            Session.FeatureMapQuality.INSUFFICIENT
        }
        val ready = quality != Session.FeatureMapQuality.INSUFFICIENT

        mainHandler.post {
            qrPlacementButton?.apply {
                isEnabled = ready
                alpha = if (ready) 1f else 0.45f
            }
            qrPlacementStatusText?.text = if (ready) {
                "PERSISTENCE READY (${quality.name}) — position the QR portal, then tap LOCK START PORTAL."
            } else {
                "SCAN AROUND THE START — move slowly so ARCore can learn enough visual detail to persist this portal."
            }
        }
    }

    private fun setPersistentPortalStatus(text: String) {
        mainHandler.post {
            qrPlacementStatusText?.text = text
        }
    }

    private fun hostPersistentStartPortal(
        activeSession: Session,
        targetPose: Pose,
    ) {
        persistentPortalHostFuture?.cancel()
        persistentPortalHostFuture = null

        try {
            persistentPortalHostAnchor?.detach()
        } catch (_: Exception) {
        }

        val localAnchor = activeSession.createAnchor(targetPose)
        persistentPortalHostAnchor = localAnchor
        persistentPortalHosting = true

        if (persistentPortalLocalDevMode) {
            val localId = "localdev:${System.currentTimeMillis()}"
            emit(
                mapOf(
                    "type" to "status",
                    "tracking" to "PERSISTENT_PORTAL_HOSTED",
                    "cloud_anchor_id" to localId,
                    "message" to
                        "Local dev portal saved. Cross-session physical position is mocked.",
                ),
            )
            finishQrPlacement(
                mapOf(
                    "cloud_anchor_id" to localId,
                ),
            )
            return
        }

        mainHandler.post {
            qrPlacementButton?.apply {
                isEnabled = false
                alpha = 0.45f
                text = "HOSTING PORTAL..."
            }
            qrPlacementStatusText?.text =
                "SAVING START PORTAL — keep the phone steady and keep this area visible."
        }

        persistentPortalHostFuture = activeSession.hostCloudAnchorAsync(
            localAnchor,
            1,
        ) { cloudAnchorId, state ->
            persistentPortalHostFuture = null

            if (state == Anchor.CloudAnchorState.SUCCESS &&
                !cloudAnchorId.isNullOrBlank()
            ) {
                emit(
                    mapOf(
                        "type" to "status",
                        "tracking" to "PERSISTENT_PORTAL_HOSTED",
                        "cloud_anchor_id" to cloudAnchorId,
                        "message" to "Persistent start portal saved.",
                    ),
                )
                finishQrPlacement(
                    mapOf(
                        "cloud_anchor_id" to cloudAnchorId,
                    ),
                )
            } else {
                persistentPortalHosting = false
                try {
                    persistentPortalHostAnchor?.detach()
                } catch (_: Exception) {
                }
                persistentPortalHostAnchor = null

                mainHandler.post {
                    qrPlacementButton?.apply {
                        text = "LOCK START PORTAL"
                        isEnabled = true
                        alpha = 1f
                    }
                    qrPlacementStatusText?.text =
                        "PORTAL SAVE FAILED (${state.name}). Check internet / ARCore Cloud setup, then try again."
                }
                emitError(
                    "CLOUD_ANCHOR_HOST_FAILED",
                    "Cloud Anchor hosting failed: ${state.name}",
                )
            }
        }
    }
    private fun setQrPlacementTrackingReady(ready: Boolean) {
        if (qrPlacementTrackingReady == ready) return
        qrPlacementTrackingReady = ready

        mainHandler.post {
            if (persistentPortalMappingMode) {
                if (!ready) {
                    qrPlacementButton?.isEnabled = false
                    qrPlacementButton?.alpha = 0.45f
                    qrPlacementStatusText?.text =
                        "TRACKING PAUSED — move slowly until ARCore recovers."
                }
                return@post
            }

            qrPlacementButton?.isEnabled = ready
            qrPlacementButton?.alpha = if (ready) 1f else 0.45f
            if (ready) {
                qrPlacementStatusText?.text =
                    "QR READY — move/aim the phone, adjust distance, then tap PLACE QR HERE."
            } else {
                qrPlacementStatusText?.text =
                    "TRACKING PAUSED — move slowly until ARCore recovers."
            }
        }
    }

    private fun finishQrPlacement(payload: Map<String, Any>?) {
        if (!qrPlacementMode && qrPlacementCompletion == null) return

        qrPlacementMode = false
        qrPlacementRequested = false
        qrPlacementTrackingReady = false
        val callback = qrPlacementCompletion
        qrPlacementCompletion = null

        mainHandler.post {
            val overlay = qrPlacementOverlay
            val glView = surfaceView
            qrPlacementOverlay = null
            qrPlacementStatusText = null
            qrPlacementDistanceText = null
            qrPlacementButton = null

            if (overlay != null && glView != null && glView.parent === overlay) {
                overlay.removeView(glView)
                (overlay.parent as? ViewGroup)?.removeView(overlay)
                activity.addContentView(
                    glView,
                    FrameLayout.LayoutParams(2, 2).apply {
                        gravity = Gravity.BOTTOM or Gravity.END
                    },
                )
            } else {
                (overlay?.parent as? ViewGroup)?.removeView(overlay)
                glView?.layoutParams = FrameLayout.LayoutParams(2, 2).apply {
                    gravity = Gravity.BOTTOM or Gravity.END
                }
            }

            qrPlacementRenderer.setBitmap(null)
            qrPlacementBitmap?.recycle()
            qrPlacementBitmap = null

            callback?.invoke(payload)
        }
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
        val oldQrPlacementOverlay = qrPlacementOverlay
        val oldMappingVisualOverlay = mappingVisualOverlay
        val pendingQrPlacement = qrPlacementCompletion
        val oldView = surfaceView
        navigationOverlay = null
        navigationStatusText = null
        navigationArrowText = null
        navigationAlignButton = null
        navigationReanchorButton = null
        navigationExitButton = null
        qrPlacementOverlay = null
        mappingVisualOverlay = null
        mappingVisualStatusText = null
        qrPlacementStatusText = null
        qrPlacementDistanceText = null
        qrPlacementButton = null
        qrPlacementCompletion = null
        qrPlacementMode = false
        qrPlacementRequested = false
        qrPlacementTrackingReady = false
        surfaceView = null

        val removeViews = Runnable {
            (oldOverlay?.parent as? ViewGroup)?.removeView(oldOverlay)
            (oldQrPlacementOverlay?.parent as? ViewGroup)?.removeView(oldQrPlacementOverlay)
            (oldMappingVisualOverlay?.parent as? ViewGroup)?.removeView(oldMappingVisualOverlay)
            if (oldOverlay == null && oldMappingVisualOverlay == null) {
                (oldView?.parent as? ViewGroup)?.removeView(oldView)
            }
            qrPlacementRenderer.setBitmap(null)
            qrPlacementBitmap?.recycle()
            qrPlacementBitmap = null
            pendingQrPlacement?.invoke(null)
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
        clearVisualAnchorConfiguration()
        clearMappingVisualAnchorConfiguration()
        clearPersistentPortalState()
        clearNavigationCloudAnchorState()
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

        backgroundRenderer.createOnGlThread()
        qrPlacementRenderer.createOnGlThread()
        if (navigationMode) {
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

            if (navigationMode || qrPlacementMode || mappingVisualAnchorEnabled) {
                backgroundRenderer.draw(frame, cameraTextureId)
            }

            if (camera.trackingState != TrackingState.TRACKING) {
                val reason = camera.trackingFailureReason.name
                emitTrackingState(
                    state = camera.trackingState.name,
                    reason = reason,
                )
                if (qrPlacementMode) {
                    setQrPlacementTrackingReady(false)
                }
                if (mappingVisualAnchorEnabled) {
                    setMappingVisualHud(
                        "TRACKING PAUSED — move slowly until ARCore recovers.",
                    )
                }
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

            if (qrPlacementMode) {
                setQrPlacementTrackingReady(true)
                handleQrPlacementFrame(
                    currentPose = currentPose,
                    camera = camera,
                )
                return
            }

            if (mappingVisualAnchorEnabled) {
                val locked = tryLockMappingStartQr(
                    activeSession = activeSession,
                    currentPose = currentPose,
                )
                if (!locked) {
                    emitTrackingState("TRACKING")
                    return
                }
            }

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
                if (!navigationAligned &&
                    navigationCloudAnchorId != null
                ) {
                    beginPersistentPortalResolve(
                        activeSession = activeSession,
                        currentPose = currentPose,
                    )
                    emitTrackingState("TRACKING")
                    setNavigationArrowVisible(false)
                    return
                }

                if (!navigationAligned &&
                    navigationVisualAnchorEnabled &&
                    navigationCalibrationStart == null
                ) {
                    tryLockVisualAnchor(
                        activeSession = activeSession,
                        currentPose = currentPose,
                    )
                }

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

                val routeAnchor = navigationWorldAnchor
                if (routeAnchor == null ||
                    routeAnchor.trackingState != TrackingState.TRACKING
                ) {
                    setNavigationArrowVisible(false)
                    setNavigationHud(
                        if (routeAnchor?.trackingState == TrackingState.STOPPED) {
                            "ANCHOR LOST — scan a known location before continuing."
                        } else {
                            "ANCHOR TRACKING PAUSED — stop walking and keep visible detail in frame."
                        },
                    )
                    if (routeAnchor?.trackingState == TrackingState.STOPPED) {
                        mainHandler.post {
                            navigationReanchorButton?.visibility =
                                android.view.View.VISIBLE
                        }
                    }
                    return
                }

                if (navigationCloudAnchorId != null) {
                    drawPersistentNavigationPortal(
                        camera = camera,
                        anchor = routeAnchor,
                    )
                    if (!updatePersistentPortalActivation(
                            currentPose = currentPose,
                            anchor = routeAnchor,
                        )
                    ) {
                        emitTrackingState("TRACKING")
                        setNavigationArrowVisible(false)
                        return
                    }
                }

                if (!acceptNavigationPose(
                        currentPose = currentPose,
                        timestampNanos = frame.timestamp,
                    )
                ) {
                    return
                }

                val local = navigationLocalPosition(currentPose)
                val worldBasis = navigationWorldBasis()
                emitHorizontalPose(
                    currentPose = currentPose,
                    local = local,
                    timestampNanos = frame.timestamp,
                    originForwardX = worldBasis.forwardX,
                    originForwardZ = worldBasis.forwardZ,
                    originRightX = worldBasis.rightX,
                    originRightZ = worldBasis.rightZ,
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
                    val userWorldPoint = navigationUserWorldPoint(local)

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

    private fun tryLockMappingStartQr(
        activeSession: Session,
        currentPose: Pose,
    ): Boolean {
        if (!mappingVisualAnchorEnabled) return true

        val target = activeSession
            .getAllTrackables(AugmentedImage::class.java)
            .firstOrNull { image ->
                image.name == mappingVisualImageName &&
                    image.trackingState == TrackingState.TRACKING &&
                    image.trackingMethod ==
                        AugmentedImage.TrackingMethod.FULL_TRACKING
            }
            ?: run {
                resetMappingVisualSamples()
                setMappingVisualHud(
                    "LOOK FOR START QR — point the camera at the upright " +
                        "16 cm ${mappingVisualAnchorLabel} QR.",
                )
                return false
            }

        val imagePose = target.centerPose
        val position = imagePose.translation
        var normal = imagePose.getTransformedAxis(1, 1f)

        val toCameraX = currentPose.tx() - position[0]
        val toCameraY = currentPose.ty() - position[1]
        val toCameraZ = currentPose.tz() - position[2]
        val facingDot =
            normal[0] * toCameraX +
                normal[1] * toCameraY +
                normal[2] * toCameraZ
        if (facingDot < 0f) {
            normal = floatArrayOf(-normal[0], -normal[1], -normal[2])
        }

        val horizontalLength = sqrt(
            normal[0] * normal[0] + normal[2] * normal[2],
        )
        if (horizontalLength < 0.35f) {
            resetMappingVisualSamples()
            setMappingVisualHud(
                "QR DETECTED, BUT NOT UPRIGHT — hold/mount it vertically.",
            )
            return false
        }

        val forwardX = normal[0] / horizontalLength
        val forwardZ = normal[2] / horizontalLength

        mappingVisualSampleCount++
        mappingVisualPositionX += position[0]
        mappingVisualPositionY += position[1]
        mappingVisualPositionZ += position[2]
        mappingVisualForwardX += forwardX
        mappingVisualForwardZ += forwardZ

        if (mappingVisualSampleCount < mappingVisualSamplesRequired) {
            setMappingVisualHud(
                "START QR DETECTED — hold steady " +
                    "$mappingVisualSampleCount/$mappingVisualSamplesRequired",
            )
            return false
        }

        val n = mappingVisualSampleCount.toFloat()
        val originX = mappingVisualPositionX / n
        val originY = mappingVisualPositionY / n
        val originZ = mappingVisualPositionZ / n
        var averageForwardX = mappingVisualForwardX / n
        var averageForwardZ = mappingVisualForwardZ / n
        val forwardLength = sqrt(
            averageForwardX * averageForwardX +
                averageForwardZ * averageForwardZ,
        )
        if (forwardLength < 0.20f) {
            resetMappingVisualSamples()
            return false
        }
        averageForwardX /= forwardLength
        averageForwardZ /= forwardLength

        trackingOriginPosition = floatArrayOf(originX, originY, originZ)
        trackingForwardX = averageForwardX
        trackingForwardZ = averageForwardZ
        trackingRightX = -trackingForwardZ
        trackingRightZ = trackingForwardX

        mappingVisualAnchorEnabled = false
        resetMappingVisualSamples()
        finishMappingVisualOverlay()
        emitStatus("MAPPING_START_QR_LOCKED")
        return true
    }

    private fun setMappingVisualHud(text: String) {
        if (mappingVisualLastHudText == text) return
        mappingVisualLastHudText = text
        mainHandler.post {
            mappingVisualStatusText?.text = text
        }
    }
    private fun beginPersistentPortalResolve(
        activeSession: Session,
        currentPose: Pose,
    ) {
        val cloudId = navigationCloudAnchorId ?: return
        if (navigationAligned || navigationCloudResolveAttempted) return

        navigationCloudResolveAttempted = true

        if (navigationLocalDevPortal) {
            val forward = horizontalForward(currentPose)
            val cameraPosition = currentPose.translation
            val portalPosition = floatArrayOf(
                cameraPosition[0] + forward[0] * 1.0f,
                cameraPosition[1],
                cameraPosition[2] + forward[2] * 1.0f,
            )
            val portalPose = horizontalPoseFromForward(
                position = portalPosition,
                forwardX = forward[0],
                forwardZ = forward[2],
            )

            releaseNavigationAnchor()
            navigationWorldAnchor = activeSession.createAnchor(portalPose)
            navigationForwardX = 0f
            navigationForwardZ = -1f
            navigationRightX = 1f
            navigationRightZ = 0f
            navigationAligned = true
            navigationPortalActivated = false
            navigationPortalFocusFrames = 0
            resetNavigationCalibration()
            resetNavigationContinuity()
            activeRouteIndex = 1

            setNavigationAlignedUi()
            setNavigationHud(
                "LOCAL DEV PORTAL READY — center the floating QR to activate the route. " +
                    "Its old real-world position is not being restored in this mode.",
            )
            emit(
                mapOf(
                    "type" to "status",
                    "tracking" to "PERSISTENT_PORTAL_RESOLVED",
                    "message" to
                        "Local dev portal recreated near the current camera.",
                ),
            )
            return
        }
        setNavigationHud(
            "FINDING START PORTAL — slowly look around the mapped entrance area...",
        )
        mainHandler.post {
            navigationAlignButton?.visibility = android.view.View.GONE
            navigationReanchorButton?.visibility = android.view.View.GONE
        }

        navigationResolveFuture = activeSession.resolveCloudAnchorAsync(
            cloudId,
        ) { resolvedAnchor, state ->
            navigationResolveFuture = null
            val glView = surfaceView
            if (glView == null) {
                try { resolvedAnchor?.detach() } catch (_: Exception) {}
                return@resolveCloudAnchorAsync
            }

            glView.queueEvent {
                if (state == Anchor.CloudAnchorState.SUCCESS &&
                    resolvedAnchor != null
                ) {
                    releaseNavigationAnchor()
                    navigationWorldAnchor = resolvedAnchor
                    navigationForwardX = 0f
                    navigationForwardZ = -1f
                    navigationRightX = 1f
                    navigationRightZ = 0f
                    navigationAligned = true
                    navigationPortalActivated = false
                    navigationPortalFocusFrames = 0
                    resetNavigationCalibration()
                    resetNavigationContinuity()
                    activeRouteIndex = 1

                    setNavigationAlignedUi()
                    setNavigationHud(
                        "START PORTAL FOUND — point the camera at the floating QR to begin.",
                    )
                    emitStatus("PERSISTENT_PORTAL_RESOLVED")
                } else {
                    try { resolvedAnchor?.detach() } catch (_: Exception) {}
                    setNavigationArrowVisible(false)
                    setNavigationHud(
                        "COULD NOT RESOLVE START PORTAL (${state.name}). " +
                            "Return near the mapped entrance with internet access and retry.",
                    )
                    emitError(
                        "CLOUD_ANCHOR_RESOLVE_FAILED",
                        "Cloud Anchor resolve failed: ${state.name}",
                    )
                }
            }
        }
    }

    private fun drawPersistentNavigationPortal(
        camera: com.google.ar.core.Camera,
        anchor: Anchor,
    ) {
        val pose = anchor.pose
        qrPlacementRenderer.draw(
            camera = camera,
            center = pose.translation,
            rightAxis = pose.getTransformedAxis(0, 1f),
            upAxis = pose.getTransformedAxis(1, 1f),
            sizeMeters = qrPlacementWidthMeters,
        )
    }

    private fun updatePersistentPortalActivation(
        currentPose: Pose,
        anchor: Anchor,
    ): Boolean {
        if (navigationPortalActivated) return true

        val portal = anchor.pose.translation
        val cameraPosition = currentPose.translation
        val dx = portal[0] - cameraPosition[0]
        val dy = portal[1] - cameraPosition[1]
        val dz = portal[2] - cameraPosition[2]
        val distance = sqrt(dx * dx + dy * dy + dz * dz)
        if (distance < 0.001f) {
            navigationPortalFocusFrames = 0
            return false
        }

        val cameraForward = currentPose.getTransformedAxis(2, -1f)
        val inverseDistance = 1f / distance
        val dot =
            cameraForward[0] * dx * inverseDistance +
                cameraForward[1] * dy * inverseDistance +
                cameraForward[2] * dz * inverseDistance

        val centered = dot >= 0.94f && distance in 0.30f..4.00f
        navigationPortalFocusFrames = if (centered) {
            navigationPortalFocusFrames + 1
        } else {
            0
        }

        if (navigationPortalFocusFrames >= navigationPortalFocusFramesRequired) {
            navigationPortalActivated = true
            setNavigationHud(
                "PORTAL SCANNED — route activated. Follow the green AR path.",
            )
            emitStatus("PERSISTENT_PORTAL_ACTIVATED")
            return true
        }

        val progress =
            ((navigationPortalFocusFrames.toFloat() /
                navigationPortalFocusFramesRequired.toFloat()) * 100f).toInt()
        setNavigationHud(
            if (centered) {
                "SCANNING START PORTAL — hold steady ${progress}%"
            } else {
                "CENTER THE FLOATING START QR IN THE CAMERA TO BEGIN"
            },
        )
        return false
    }
    private fun configurePersistentPortalPreview(
        png: ByteArray?,
        widthMeters: Float?,
        label: String?,
    ) {
        qrPlacementRenderer.setBitmap(null)
        qrPlacementBitmap?.recycle()
        qrPlacementBitmap = null

        if (png == null || png.isEmpty()) return
        val bitmap = BitmapFactory.decodeByteArray(png, 0, png.size) ?: return

        qrPlacementBitmap = bitmap
        qrPlacementWidthMeters = widthMeters?.takeIf { it > 0f } ?: 0.16f
        persistentPortalLabel = label ?: navigationStartLabel
        qrPlacementRenderer.setBitmap(bitmap)
    }

    private fun configureVisualAnchor(
        png: ByteArray?,
        widthMeters: Float?,
        label: String?,
        routeOffsetDegrees: Float?,
    ) {
        clearVisualAnchorConfiguration()

        if (png == null ||
            png.isEmpty() ||
            widthMeters == null ||
            widthMeters <= 0f
        ) {
            return
        }

        val bitmap = BitmapFactory.decodeByteArray(png, 0, png.size)
        if (bitmap == null) {
            navigationVisualSetupWarning =
                "Visual QR image could not be decoded; manual alignment is available."
            return
        }

        navigationVisualAnchorBitmap = bitmap
        navigationVisualAnchorWidthMeters = widthMeters
        navigationVisualAnchorLabel = label ?: navigationStartLabel
        navigationVisualRouteOffsetDegrees = routeOffsetDegrees ?: 0f
        navigationVisualAnchorEnabled = true
        resetVisualAnchorSamples()
    }

    private fun configureVisualImageDatabase(
        activeSession: Session,
        config: Config,
    ) {
        val database = AugmentedImageDatabase(activeSession)
        var added = false

        if (navigationVisualAnchorEnabled) {
            val bitmap = navigationVisualAnchorBitmap
            if (bitmap != null) {
                try {
                    database.addImage(
                        navigationVisualImageName,
                        bitmap,
                        navigationVisualAnchorWidthMeters,
                    )
                    added = true
                } catch (error: Exception) {
                    navigationVisualAnchorEnabled = false
                    navigationVisualSetupWarning =
                        "ARCore could not register this QR as a visual target " +
                            "(${error.javaClass.simpleName}). Use manual alignment."
                }
            }
        }

        if (mappingVisualAnchorEnabled) {
            val bitmap = mappingVisualAnchorBitmap
            if (bitmap != null) {
                try {
                    database.addImage(
                        mappingVisualImageName,
                        bitmap,
                        mappingVisualAnchorWidthMeters,
                    )
                    added = true
                } catch (error: Exception) {
                    mappingVisualAnchorEnabled = false
                    emitError(
                        "MAPPING_QR_DATABASE_ERROR",
                        "ARCore could not register the mapping start QR: " +
                            error.javaClass.simpleName,
                    )
                }
            }
        }

        if (added) {
            config.augmentedImageDatabase = database
        }
    }

    private fun clearPersistentPortalState() {
        persistentPortalHostFuture?.cancel()
        persistentPortalHostFuture = null
        try {
            persistentPortalHostAnchor?.detach()
        } catch (_: Exception) {
        }
        persistentPortalHostAnchor = null
        persistentPortalMappingMode = false
        persistentPortalLocalDevMode = false
        persistentPortalHosting = false
        persistentPortalLabel = "Start portal"
    }

    private fun clearNavigationCloudAnchorState() {
        navigationResolveFuture?.cancel()
        navigationResolveFuture = null
        navigationCloudResolveAttempted = false
        navigationCloudAnchorId = null
        navigationLocalDevPortal = false
        navigationPortalActivated = false
        navigationPortalFocusFrames = 0
    }

    private fun clearMappingVisualAnchorConfiguration() {
        mappingVisualAnchorBitmap?.recycle()
        mappingVisualAnchorBitmap = null
        mappingVisualAnchorWidthMeters = 0f
        mappingVisualAnchorLabel = ""
        mappingVisualAnchorEnabled = false
        mappingVisualStatusText = null
        mappingVisualLastHudText = null
        resetMappingVisualSamples()
    }

    private fun resetMappingVisualSamples() {
        mappingVisualSampleCount = 0
        mappingVisualPositionX = 0f
        mappingVisualPositionY = 0f
        mappingVisualPositionZ = 0f
        mappingVisualForwardX = 0f
        mappingVisualForwardZ = 0f
    }
    private fun clearVisualAnchorConfiguration() {
        navigationVisualAnchorBitmap?.recycle()
        navigationVisualAnchorBitmap = null
        navigationVisualAnchorWidthMeters = 0f
        navigationVisualAnchorLabel = ""
        navigationVisualRouteOffsetDegrees = 0f
        navigationVisualAnchorEnabled = false
        navigationVisualSetupWarning = null
        resetVisualAnchorSamples()
    }

    private fun resetVisualAnchorSamples() {
        navigationVisualSampleCount = 0
        navigationVisualPositionX = 0f
        navigationVisualPositionZ = 0f
        navigationVisualForwardX = 0f
        navigationVisualForwardZ = 0f
    }

    private fun tryLockVisualAnchor(
        activeSession: Session,
        currentPose: Pose,
    ): Boolean {
        if (!navigationVisualAnchorEnabled || navigationAligned) return false

        val target = activeSession
            .getAllTrackables(AugmentedImage::class.java)
            .firstOrNull { image ->
                image.name == navigationVisualImageName &&
                    image.trackingState == TrackingState.TRACKING &&
                    image.trackingMethod ==
                        AugmentedImage.TrackingMethod.FULL_TRACKING
            }
            ?: run {
                resetVisualAnchorSamples()
                return false
            }

        val imagePose = target.centerPose
        val position = imagePose.translation

        // ARCore Augmented Images lie in their local X/Z plane. Local +Y is
        // the image normal. Flip it, if necessary, so "forward" always points
        // out of the poster toward the person currently scanning it.
        var normal = imagePose.getTransformedAxis(1, 1f)
        val toCameraX = currentPose.tx() - position[0]
        val toCameraY = currentPose.ty() - position[1]
        val toCameraZ = currentPose.tz() - position[2]
        val facingDot =
            normal[0] * toCameraX +
                normal[1] * toCameraY +
                normal[2] * toCameraZ
        if (facingDot < 0f) {
            normal = floatArrayOf(-normal[0], -normal[1], -normal[2])
        }

        val horizontalLength = sqrt(
            normal[0] * normal[0] + normal[2] * normal[2],
        )
        if (horizontalLength < 0.35f) {
            resetVisualAnchorSamples()
            setNavigationHud(
                "QR detected, but it is not vertical enough for reliable " +
                    "horizontal orientation. Mount/hold it upright.",
            )
            return false
        }

        val forwardX = normal[0] / horizontalLength
        val forwardZ = normal[2] / horizontalLength

        navigationVisualSampleCount++
        navigationVisualPositionX += position[0]
        navigationVisualPositionZ += position[2]
        navigationVisualForwardX += forwardX
        navigationVisualForwardZ += forwardZ

        if (navigationVisualSampleCount < navigationVisualSamplesRequired) {
            setNavigationHud(
                "QR DETECTED — hold steady " +
                    "$navigationVisualSampleCount/$navigationVisualSamplesRequired",
            )
            return false
        }

        val sampleCount = navigationVisualSampleCount.toFloat()
        val averageX = navigationVisualPositionX / sampleCount
        val averageZ = navigationVisualPositionZ / sampleCount
        var averageForwardX = navigationVisualForwardX / sampleCount
        var averageForwardZ = navigationVisualForwardZ / sampleCount
        val forwardLength = sqrt(
            averageForwardX * averageForwardX +
                averageForwardZ * averageForwardZ,
        )
        if (forwardLength < 0.20f) {
            resetVisualAnchorSamples()
            return false
        }
        averageForwardX /= forwardLength
        averageForwardZ /= forwardLength

        val routeForward = rotateHorizontalHeading(
            x = averageForwardX,
            z = averageForwardZ,
            degreesClockwise = navigationVisualRouteOffsetDegrees,
        )

        val anchorPose = horizontalPoseFromForward(
            position = floatArrayOf(
                averageX,
                currentPose.ty(),
                averageZ,
            ),
            forwardX = routeForward[0],
            forwardZ = routeForward[1],
        )

        releaseNavigationAnchor()
        navigationWorldAnchor = activeSession.createAnchor(anchorPose)

        // Flutter expressed route points in a frame whose +forward axis is
        // the verified venue heading of this QR's outward normal.
        navigationForwardX = 0f
        navigationForwardZ = -1f
        navigationRightX = 1f
        navigationRightZ = 0f
        navigationAligned = true
        navigationVisualAnchorEnabled = false
        resetNavigationCalibration()
        resetNavigationContinuity()
        navigationLastAcceptedPosition = currentPose.translation.copyOf()

        val local = navigationLocalPosition(currentPose)
        activeRouteIndex = nearestNavigationPointIndex(local)

        setNavigationAlignedUi()
        setNavigationHud(
            "VISUAL QR LOCKED: ${navigationVisualAnchorLabel.ifBlank { navigationStartLabel }}\n" +
                "Position + direction measured from the physical marker.",
        )
        emitStatus("VISUAL_ANCHOR_LOCKED")
        resetVisualAnchorSamples()
        return true
    }

    private fun rotateHorizontalHeading(
        x: Float,
        z: Float,
        degreesClockwise: Float,
    ): FloatArray {
        val radians = Math.toRadians(degreesClockwise.toDouble())
        val c = kotlin.math.cos(radians).toFloat()
        val sn = kotlin.math.sin(radians).toFloat()
        return floatArrayOf(
            x * c - z * sn,
            x * sn + z * c,
        )
    }

    private fun horizontalPoseFromForward(
        position: FloatArray,
        forwardX: Float,
        forwardZ: Float,
    ): Pose {
        val yaw = atan2(-forwardX, -forwardZ)
        val half = yaw / 2f
        return Pose(
            position.copyOf(),
            floatArrayOf(0f, sin(half), 0f, cos(half)),
        )
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
        releaseNavigationAnchor()

        val activeSession = session ?: run {
            setNavigationHud("ARCore session is not ready. Try again.")
            return
        }

        val anchorPose = horizontalAnchorPose(pose)
        val anchor = activeSession.createAnchor(anchorPose)
        navigationWorldAnchor = anchor

        val start = floatArrayOf(0f, 0f, 0f)
        navigationCalibrationStart = start
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
        val localTranslation = navigationAnchorLocalPoint(currentPose.translation)
            ?: return
        appendNavigationCalibrationSample(localTranslation)

        val dx = localTranslation[0] - start[0]
        val dz = localTranslation[2] - start[2]
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
        val localTranslation = navigationAnchorLocalPoint(pose.translation)
            ?: return
        appendNavigationCalibrationSample(localTranslation)

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

        navigationCalibrationStart ?: return
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
                "ARCore anchor locked. Follow the green target.",
        )
    }

    private fun rejectNavigationCalibration(fit: CalibrationFit) {
        resetNavigationCalibration()
        releaseNavigationAnchor()
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
                releaseNavigationAnchor()
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
        releaseNavigationAnchor()
        navigationForwardX = 0f
        navigationForwardZ = -1f
        navigationRightX = 1f
        navigationRightZ = 0f
        resetNavigationCalibration()
        resetNavigationContinuity()
    }

    private data class NavigationWorldBasis(
        val forwardX: Float,
        val forwardZ: Float,
        val rightX: Float,
        val rightZ: Float,
    )

    private fun horizontalAnchorPose(cameraPose: Pose): Pose {
        val forward = horizontalForward(cameraPose)
        val yaw = atan2(-forward[0], -forward[2])
        val half = yaw / 2f
        return Pose(
            cameraPose.translation.copyOf(),
            floatArrayOf(0f, sin(half), 0f, cos(half)),
        )
    }

    private fun releaseNavigationAnchor() {
        try {
            navigationWorldAnchor?.detach()
        } catch (_: Exception) {
        }
        navigationWorldAnchor = null
    }

    private fun navigationAnchorLocalPoint(
        worldPoint: FloatArray,
    ): FloatArray? {
        val anchor = navigationWorldAnchor ?: return null
        if (anchor.trackingState == TrackingState.STOPPED) return null
        return anchor.pose.inverse().transformPoint(worldPoint)
    }

    private fun navigationWorldBasis(): NavigationWorldBasis {
        val anchor = navigationWorldAnchor
            ?: return NavigationWorldBasis(0f, -1f, 1f, 0f)

        val forwardWorld = anchor.pose.rotateVector(
            floatArrayOf(navigationForwardX, 0f, navigationForwardZ),
        )
        val rightWorld = anchor.pose.rotateVector(
            floatArrayOf(navigationRightX, 0f, navigationRightZ),
        )

        fun horizontalize(vector: FloatArray): FloatArray {
            val length = sqrt(vector[0] * vector[0] + vector[2] * vector[2])
            if (length < 0.0001f) return floatArrayOf(0f, 0f, -1f)
            return floatArrayOf(vector[0] / length, 0f, vector[2] / length)
        }

        val forward = horizontalize(forwardWorld)
        val right = horizontalize(rightWorld)
        return NavigationWorldBasis(
            forwardX = forward[0],
            forwardZ = forward[2],
            rightX = right[0],
            rightZ = right[2],
        )
    }

    private fun navigationUserWorldPoint(local: LocalPosition): FloatArray {
        val anchor = navigationWorldAnchor
            ?: return floatArrayOf(0f, -1.10f, 0f)
        val anchorLocal = floatArrayOf(
            navigationRightX * local.right +
                navigationForwardX * local.forward,
            -1.10f,
            navigationRightZ * local.right +
                navigationForwardZ * local.forward,
        )
        return anchor.pose.transformPoint(anchorLocal)
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
        val anchorLocal = navigationAnchorLocalPoint(pose.translation)
            ?: return LocalPosition(0f, 0f, 0f)

        return LocalPosition(
            right =
                anchorLocal[0] * navigationRightX +
                    anchorLocal[2] * navigationRightZ,
            up = anchorLocal[1],
            forward =
                anchorLocal[0] * navigationForwardX +
                    anchorLocal[2] * navigationForwardZ,
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
        val anchor = navigationWorldAnchor ?: return emptyList()
        if (anchor.trackingState != TrackingState.TRACKING) return emptyList()

        val anchorPose = anchor.pose
        return navigationPoints.map { point ->
            val anchorLocal = floatArrayOf(
                navigationRightX * point.rightMeters +
                    navigationForwardX * point.forwardMeters,
                -1.10f,
                navigationRightZ * point.rightMeters +
                    navigationForwardZ * point.forwardMeters,
            )
            anchorPose.transformPoint(anchorLocal)
        }
    }

    private fun createMappingVisualOverlay(glView: GLSurfaceView) {
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
            text = "MAP START QR\n${mappingVisualAnchorLabel.ifBlank { "Entrance" }}"
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

        val target = TextView(activity).apply {
            text = "□"
            textSize = 82f
            gravity = Gravity.CENTER
            setTextColor(0xFF3DDC97.toInt())
        }
        overlay.addView(
            target,
            FrameLayout.LayoutParams(dp(130), dp(130)).apply {
                gravity = Gravity.CENTER
            },
        )

        val closeButton = Button(activity).apply {
            text = "×"
            textSize = 24f
            setTextColor(Color.WHITE)
            background = roundedBackground(0xB8000000.toInt(), dp(28).toFloat())
            setOnClickListener {
                emitStatus("MAPPING_QR_SCAN_CANCELLED")
                mainHandler.post { stop() }
            }
        }
        overlay.addView(
            closeButton,
            FrameLayout.LayoutParams(dp(52), dp(52)).apply {
                gravity = Gravity.TOP or Gravity.START
                setMargins(dp(14), dp(38), 0, 0)
            },
        )

        val status = TextView(activity).apply {
            text =
                "LOOK FOR START QR — point at the upright 16 cm " +
                    "${mappingVisualAnchorLabel.ifBlank { "entrance" }} QR and hold steady."
            setTextColor(Color.WHITE)
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(dp(14), dp(10), dp(14), dp(10))
            background = roundedBackground(0xB8000000.toInt(), dp(18).toFloat())
        }
        mappingVisualStatusText = status
        mappingVisualLastHudText = status.text.toString()
        overlay.addView(
            status,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            ).apply {
                gravity = Gravity.BOTTOM
                setMargins(dp(24), 0, dp(24), dp(54))
            },
        )

        activity.addContentView(
            overlay,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        mappingVisualOverlay = overlay
    }

    private fun finishMappingVisualOverlay() {
        mainHandler.post {
            val overlay = mappingVisualOverlay
            val glView = surfaceView
            mappingVisualOverlay = null
            mappingVisualStatusText = null
            mappingVisualLastHudText = null

            if (overlay != null && glView != null) {
                (glView.parent as? ViewGroup)?.removeView(glView)
                (overlay.parent as? ViewGroup)?.removeView(overlay)
                activity.addContentView(
                    glView,
                    FrameLayout.LayoutParams(2, 2).apply {
                        gravity = Gravity.BOTTOM or Gravity.END
                    },
                )
            }
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
            text = when {
                navigationVisualAnchorEnabled ->
                    "VISUAL LOCALIZATION\nPoint the camera at the upright " +
                        "16 cm $navigationVisualAnchorLabel QR and hold steady."
                navigationVisualSetupWarning != null ->
                    navigationVisualSetupWarning
                navigationAnchorLocalized ->
                    "Legacy location anchor: $navigationStartLabel\n" +
                        "Visual orientation is unavailable; use manual alignment."
                else ->
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
            text = when {
                navigationVisualAnchorEnabled -> "MANUAL FALLBACK"
                navigationAnchorLocalized -> "SET QR POSITION"
                else -> "SET START"
            }
            textSize = 14f
            setTextColor(Color.BLACK)
            background = roundedBackground(
                0xFF72A7FF.toInt(),
                dp(22).toFloat(),
            )
            setOnClickListener {
                if (navigationVisualAnchorEnabled) {
                    navigationVisualAnchorEnabled = false
                    resetVisualAnchorSamples()
                }
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
        if (navigationCloudAnchorId != null) {
            align.visibility = android.view.View.GONE
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
            navigationReanchorButton?.visibility =
                if (navigationCloudAnchorId == null) {
                    android.view.View.VISIBLE
                } else {
                    android.view.View.GONE
                }
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
        val oldMappingVisualOverlay = mappingVisualOverlay
        val oldView = surfaceView
        navigationOverlay = null
        mappingVisualOverlay = null
        mappingVisualStatusText = null
        navigationStatusText = null
        navigationArrowText = null
        navigationAlignButton = null
        navigationReanchorButton = null
        navigationExitButton = null
        surfaceView = null

        if (oldOverlay != null || oldView != null) {
            mainHandler.post {
                (oldOverlay?.parent as? ViewGroup)?.removeView(oldOverlay)
                (oldMappingVisualOverlay?.parent as? ViewGroup)
                    ?.removeView(oldMappingVisualOverlay)
                if (oldOverlay == null && oldMappingVisualOverlay == null) {
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
        clearMappingVisualAnchorConfiguration()
    }
}
