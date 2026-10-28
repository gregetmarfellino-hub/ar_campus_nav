package com.example.ar_campus_nav

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity(), SensorEventListener {
    companion object {
        private const val NATIVE_CHANNEL = "ar_campus_nav/native"
        private const val STEP_CHANNEL = "ar_campus_nav/steps"
        private const val AR_POSE_CHANNEL = "ar_campus_nav/ar_pose"
        private const val ACTIVITY_PERMISSION_REQUEST = 7401
        private const val CAMERA_PERMISSION_REQUEST = 7402
    }

    private lateinit var sensorManager: SensorManager
    private var stepSensor: Sensor? = null
    private var stepSink: EventChannel.EventSink? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingCameraPermissionResult: MethodChannel.Result? = null
    private var arPoseSink: EventChannel.EventSink? = null
    private var arCoreTrackingEngine: ArCoreTrackingEngine? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        stepSensor = sensorManager.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NATIVE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isStepSensorAvailable" -> result.success(stepSensor != null)
                "ensureActivityRecognitionPermission" -> ensureActivityRecognitionPermission(result)
                "saveMapping" -> saveMapping(call.argument("id"), call.argument("json"), result)
                "listMappings" -> result.success(listMappings())
                "loadMapping" -> loadMapping(call.argument("id"), result)
                "deleteMapping" -> deleteMapping(call.argument("id"), result)
                "ensureCameraPermission" -> ensureCameraPermission(result)
                "arCoreAvailability" -> result.success(arEngine().availabilityLabel())
                "startArTracking" -> {
                    val mappingVisualAnchorPng =
                        call.argument<ByteArray>("mapping_visual_anchor_png")
                    val mappingVisualAnchorWidthMeters =
                        (call.argument<Number>("mapping_visual_anchor_width_m"))
                            ?.toFloat()
                    val mappingVisualAnchorLabel =
                        call.argument<String>("mapping_visual_anchor_label")

                    result.success(
                        if (
                            mappingVisualAnchorPng != null &&
                            mappingVisualAnchorPng.isNotEmpty() &&
                            mappingVisualAnchorWidthMeters != null &&
                            mappingVisualAnchorWidthMeters > 0f
                        ) {
                            arEngine().startMappingWithVisualAnchor(
                                visualAnchorPng = mappingVisualAnchorPng,
                                visualAnchorWidthMeters =
                                    mappingVisualAnchorWidthMeters,
                                visualAnchorLabel =
                                    mappingVisualAnchorLabel ?: "Start QR",
                            )
                        } else {
                            arEngine().start()
                        },
                    )
                }
                "startArNavigation" -> {
                    val destination =
                        call.argument<String>("destination") ?: "Destination"
                    val startLabel =
                        call.argument<String>("start_label") ?: "Route start"
                    val anchorLocalized =
                        call.argument<Boolean>("anchor_localized") ?: false
                    val visualAnchorPng =
                        call.argument<ByteArray>("visual_anchor_png")
                    val visualAnchorWidthMeters =
                        (call.argument<Number>("visual_anchor_width_m"))
                            ?.toFloat()
                    val visualAnchorLabel =
                        call.argument<String>("visual_anchor_label")
                    val visualAnchorRouteOffsetDegrees =
                        (call.argument<Number>(
                            "visual_anchor_route_offset_deg",
                        ))?.toFloat()
                    val rawPoints =
                        call.argument<List<Map<String, Any?>>>("points") ?: emptyList()

                    val points = rawPoints.mapNotNull { item ->
                        val right = (item["right"] as? Number)?.toFloat()
                        val forward = (item["forward"] as? Number)?.toFloat()
                        if (right == null || forward == null) {
                            null
                        } else {
                            ArCoreTrackingEngine.RoutePoint(
                                rightMeters = right,
                                forwardMeters = forward,
                                label = item["label"]?.toString() ?: "Route point",
                                semantic = item["semantic"] as? Boolean ?: false,
                            )
                        }
                    }

                    result.success(
                        arEngine().startNavigation(
                            destination = destination,
                            points = points,
                            startLabel = startLabel,
                            anchorLocalized = anchorLocalized,
                            visualAnchorPng = visualAnchorPng,
                            visualAnchorWidthMeters = visualAnchorWidthMeters,
                            visualAnchorLabel = visualAnchorLabel,
                            visualAnchorRouteOffsetDegrees =
                                visualAnchorRouteOffsetDegrees,
                            persistentAnchorId = persistentAnchorId,
                        ),
                    )
                }
                "placeVisualQrAnchor" -> {
                    val qrPng = call.argument<ByteArray>("qr_png")
                    val widthMeters =
                        (call.argument<Number>("qr_width_m"))?.toFloat()

                    if (qrPng == null || qrPng.isEmpty() ||
                        widthMeters == null || widthMeters <= 0f
                    ) {
                        result.error(
                            "INVALID_QR_PLACEMENT",
                            "QR bitmap and physical width are required.",
                            null,
                        )
                    } else {
                        val error = arEngine().beginVisualQrPlacement(
                            qrPng = qrPng,
                            widthMeters = widthMeters,
                        ) { placement ->
                            result.success(placement)
                        }
                        if (error != null) {
                            result.error(
                                "QR_PLACEMENT_UNAVAILABLE",
                                error,
                                null,
                            )
                        }
                    }
                }
                "hostPersistentStartAnchor" -> {
                    val ttlDays =
                        (call.argument<Number>("ttl_days"))?.toInt() ?: 1
                    val error = arEngine().beginHostMappingStartAnchor(
                        ttlDays = ttlDays,
                    ) { cloudAnchorId, hostError ->
                        if (cloudAnchorId != null) {
                            result.success(cloudAnchorId)
                        } else {
                            result.error(
                                "CLOUD_ANCHOR_HOST_FAILED",
                                hostError ?: "Unknown Cloud Anchor host error.",
                                null,
                            )
                        }
                    }
                    if (error != null) {
                        result.error(
                            "CLOUD_ANCHOR_HOST_UNAVAILABLE",
                            error,
                            null,
                        )
                    }
                }
                "resetArOrigin" -> {
                    arEngine().resetOrigin()
                    result.success(null)
                }
                "stopArTracking" -> {
                    arCoreTrackingEngine?.stop()
                    arCoreTrackingEngine = null
                    result.success(null)
                }
                "stopArNavigation" -> {
                    arCoreTrackingEngine?.stop()
                    arCoreTrackingEngine = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STEP_CHANNEL,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    stepSink = events
                    startStepSensor()
                }

                override fun onCancel(arguments: Any?) {
                    stopStepSensor()
                    stepSink = null
                }
            },
        )
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AR_POSE_CHANNEL,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    arPoseSink = events
                }

                override fun onCancel(arguments: Any?) {
                    arPoseSink = null
                }
            },
        )
    }

    private fun arEngine(): ArCoreTrackingEngine {
        val existing = arCoreTrackingEngine
        if (existing != null) return existing

        return ArCoreTrackingEngine(
            activity = this,
            poseSinkProvider = { arPoseSink },
            onNavigationClosed = {
                val engine = arCoreTrackingEngine
                arCoreTrackingEngine = null
                engine?.stop()
            },
        ).also {
            arCoreTrackingEngine = it
        }
    }

    private fun ensureCameraPermission(result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }

        if (pendingCameraPermissionResult != null) {
            result.error(
                "camera_permission_pending",
                "Camera permission is already being requested.",
                null,
            )
            return
        }

        pendingCameraPermissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.CAMERA),
            CAMERA_PERMISSION_REQUEST,
        )
    }

    private fun ensureActivityRecognitionPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(true)
            return
        }

        if (checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }

        if (pendingPermissionResult != null) {
            result.error("permission_pending", "Activity recognition permission is already being requested.", null)
            return
        }

        pendingPermissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.ACTIVITY_RECOGNITION),
            ACTIVITY_PERMISSION_REQUEST,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode == ACTIVITY_PERMISSION_REQUEST) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }

        if (requestCode == CAMERA_PERMISSION_REQUEST) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingCameraPermissionResult?.success(granted)
            pendingCameraPermissionResult = null
        }
    }

    private fun startStepSensor() {
        val sensor = stepSensor ?: run {
            stepSink?.error("no_step_sensor", "This phone has no hardware step detector.", null)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            stepSink?.error(
                "permission_required",
                "Physical activity permission is required for automatic step recording.",
                null,
            )
            return
        }

        sensorManager.registerListener(
            this,
            sensor,
            SensorManager.SENSOR_DELAY_NORMAL,
        )
    }

    private fun stopStepSensor() {
        if (::sensorManager.isInitialized) {
            sensorManager.unregisterListener(this)
        }
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (event?.sensor?.type != Sensor.TYPE_STEP_DETECTOR) return
        if (event.values.isEmpty() || event.values[0] <= 0f) return

        stepSink?.success(
            mapOf(
                "timestamp_ms" to System.currentTimeMillis(),
            ),
        )
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun mappingDirectory(): File {
        return File(filesDir, "ar_nav_mappings").apply { mkdirs() }
    }

    private fun safeId(raw: String): String {
        return raw.replace(Regex("[^A-Za-z0-9_.-]"), "_")
    }

    private fun saveMapping(id: String?, json: String?, result: MethodChannel.Result) {
        if (id.isNullOrBlank() || json.isNullOrBlank()) {
            result.error("invalid_mapping", "Mapping id/json is missing.", null)
            return
        }

        try {
            val file = File(mappingDirectory(), "${safeId(id)}.json")
            file.writeText(json, Charsets.UTF_8)
            result.success(file.absolutePath)
        } catch (error: Exception) {
            result.error("save_failed", error.message, null)
        }
    }

    private fun listMappings(): List<String> {
        return mappingDirectory()
            .listFiles { file -> file.isFile && file.extension.equals("json", ignoreCase = true) }
            ?.sortedByDescending { it.lastModified() }
            ?.map { it.nameWithoutExtension }
            ?: emptyList()
    }

    private fun loadMapping(id: String?, result: MethodChannel.Result) {
        if (id.isNullOrBlank()) {
            result.error("invalid_mapping", "Mapping id is missing.", null)
            return
        }

        try {
            val file = File(mappingDirectory(), "${safeId(id)}.json")
            if (!file.exists()) {
                result.success(null)
                return
            }
            result.success(file.readText(Charsets.UTF_8))
        } catch (error: Exception) {
            result.error("load_failed", error.message, null)
        }
    }

    private fun deleteMapping(id: String?, result: MethodChannel.Result) {
        if (id.isNullOrBlank()) {
            result.error("invalid_mapping", "Mapping id is missing.", null)
            return
        }

        try {
            val file = File(mappingDirectory(), "${safeId(id)}.json")
            if (!file.exists()) {
                result.success(true)
                return
            }
            result.success(file.delete())
        } catch (error: Exception) {
            result.error("delete_failed", error.message, null)
        }
    }

    override fun onPause() {
        arCoreTrackingEngine?.pause()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        arCoreTrackingEngine?.resume()
    }

    override fun onDestroy() {
        stopStepSensor()
        arCoreTrackingEngine?.stop()
        arCoreTrackingEngine = null
        super.onDestroy()
    }
}
