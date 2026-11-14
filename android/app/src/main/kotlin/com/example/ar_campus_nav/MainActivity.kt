package com.example.ar_campus_nav

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
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
        private const val PROJECT_IMPORT_REQUEST = 7410
        private const val PROJECT_EXPORT_REQUEST = 7411
        private const val MAX_PROJECT_BYTES = 24 * 1024 * 1024
    }

    private lateinit var sensorManager: SensorManager
    private var stepSensor: Sensor? = null
    private var stepSink: EventChannel.EventSink? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingCameraPermissionResult: MethodChannel.Result? = null
    private var pendingProjectFileResult: MethodChannel.Result? = null
    private var pendingExportProjectJson: String? = null
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
                "importVenueProjectFile" -> openVenueProjectFile(result)
                "exportVenueProjectFile" -> exportVenueProjectFile(call.argument("name"), call.argument("json"), result)
                "shareVenueProjectFile" -> shareVenueProjectFile(call.argument("name"), call.argument("json"), result)
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
                    val requireVerifiedOffline =
                        call.argument<Boolean>("require_verified_offline") ?: false
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
                    val offlineReferencePng =
                        call.argument<ByteArray>("offline_reference_png")
                    val offlineReferenceWidthMeters =
                        (call.argument<Number>("offline_reference_width_m"))?.toFloat()
                    val offlineStartOffsetX =
                        (call.argument<Number>("offline_start_offset_x"))?.toFloat()
                    val offlineStartOffsetY =
                        (call.argument<Number>("offline_start_offset_y"))?.toFloat()
                    val offlineStartOffsetZ =
                        (call.argument<Number>("offline_start_offset_z"))?.toFloat()
                    val offlineStartForwardX =
                        (call.argument<Number>("offline_start_forward_x"))?.toFloat()
                    val offlineStartForwardY =
                        (call.argument<Number>("offline_start_forward_y"))?.toFloat()
                    val offlineStartForwardZ =
                        (call.argument<Number>("offline_start_forward_z"))?.toFloat()
                    val offlineExtraReferenceJson =
                        call.argument<String>("offline_extra_reference_json")
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
                            requireVerifiedOffline = requireVerifiedOffline,
                            visualAnchorPng = visualAnchorPng,
                            visualAnchorWidthMeters = visualAnchorWidthMeters,
                            visualAnchorLabel = visualAnchorLabel,
                            visualAnchorRouteOffsetDegrees =
                                visualAnchorRouteOffsetDegrees,
                            offlineReferencePng = offlineReferencePng,
                            offlineReferenceWidthMeters =
                                offlineReferenceWidthMeters,
                            offlineStartOffsetX = offlineStartOffsetX,
                            offlineStartOffsetY = offlineStartOffsetY,
                            offlineStartOffsetZ = offlineStartOffsetZ,
                            offlineStartForwardX = offlineStartForwardX,
                            offlineStartForwardY = offlineStartForwardY,
                            offlineStartForwardZ = offlineStartForwardZ,
                            offlineExtraReferenceJson = offlineExtraReferenceJson,
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
                            preserveMappingFrame = call.argument<Boolean>("preserve_mapping_frame") ?: false,
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
                "previewContinuous3dTrace" -> {
                    val rawPoints =
                        call.argument<List<Map<String, Any?>>>("points")
                            ?: emptyList()
                    val points = rawPoints.mapNotNull { item ->
                        val right = (item["right"] as? Number)?.toFloat()
                        val forward = (item["forward"] as? Number)?.toFloat()
                        val up = (item["up"] as? Number)?.toFloat()
                        if (right == null || forward == null || up == null) {
                            null
                        } else {
                            ArCoreTrackingEngine.Continuous3DTracePoint(
                                rightMeters = right,
                                forwardMeters = forward,
                                upMeters = up,
                                label = item["label"]?.toString() ?: "3D route",
                            )
                        }
                    }
                    result.success(
                        if (points.size != rawPoints.size) {
                            "INVALID_3D_TRACE"
                        } else {
                            arCoreTrackingEngine?.beginContinuous3DPreview(points)
                                ?: "NO_ACTIVE_MAPPING_SESSION"
                        },
                    )
                }
                "closeContinuous3dPreview" -> {
                    arCoreTrackingEngine?.endContinuous3DPreview()
                    result.success(null)
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


    // Android Storage Access Framework: no storage permissions and no cloud.
    // Always read/write caller-selected documents, never arbitrary paths.
    private fun openVenueProjectFile(result: MethodChannel.Result) {
        if (pendingProjectFileResult != null) {
            result.error("picker_busy", "A project document picker is already open.", null)
            return
        }
        pendingProjectFileResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/json"
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/plain", "application/octet-stream"))
            }
            startActivityForResult(intent, PROJECT_IMPORT_REQUEST)
        } catch (error: Exception) {
            pendingProjectFileResult = null
            result.error("project_picker_failed", error.message, null)
        }
    }

    private fun exportVenueProjectFile(name: String?, json: String?, result: MethodChannel.Result) {
        if (pendingProjectFileResult != null) {
            result.error("picker_busy", "A project document picker is already open.", null)
            return
        }
        if (json.isNullOrBlank() || json.toByteArray(Charsets.UTF_8).size > MAX_PROJECT_BYTES) {
            result.error("invalid_project", "Project is empty or exceeds 24 MiB.", null)
            return
        }
        pendingProjectFileResult = result
        pendingExportProjectJson = json
        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/json"
                putExtra(Intent.EXTRA_TITLE, safeProjectFileName(name))
            }
            startActivityForResult(intent, PROJECT_EXPORT_REQUEST)
        } catch (error: Exception) {
            pendingProjectFileResult = null
            pendingExportProjectJson = null
            result.error("project_export_failed", error.message, null)
        }
    }

    private fun safeProjectFileName(name: String?): String {
        val stem = (name ?: "campus.arnav.json")
            .replace(Regex("[^A-Za-z0-9_.-]"), "_")
            .take(100)
        return if (stem.endsWith(".json")) stem else "$stem.json"
    }

    private fun shareVenueProjectFile(name: String?, json: String?, result: MethodChannel.Result) {
        if (json.isNullOrBlank() || json.toByteArray(Charsets.UTF_8).size > MAX_PROJECT_BYTES) {
            result.error("invalid_project", "Project is empty or exceeds 24 MiB.", null)
            return
        }
        // FileProvider grants temporary read access to a single generated JSON.
        Thread {
            try {
                val directory = File(cacheDir, "ar_nav_shares").apply { mkdirs() }
                val file = File(directory, safeProjectFileName(name))
                file.writeText(json, Charsets.UTF_8)
                val uri = FileProvider.getUriForFile(
                    this, "${applicationContext.packageName}.share", file,
                )
                runOnUiThread {
                    try {
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "application/json"
                            putExtra(Intent.EXTRA_STREAM, uri)
                            clipData = ClipData.newUri(contentResolver, "Campus project", uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(Intent.createChooser(send, "Share offline campus project"))
                        result.success(true) // Chooser opened, not proof of delivery.
                    } catch (error: Exception) {
                        result.error("project_share_failed", error.message, null)
                    }
                }
            } catch (error: Exception) {
                runOnUiThread { result.error("project_share_failed", error.message, null) }
            }
        }.start()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PROJECT_IMPORT_REQUEST && requestCode != PROJECT_EXPORT_REQUEST) return

        val callback = pendingProjectFileResult
        pendingProjectFileResult = null
        val exportJson = pendingExportProjectJson
        pendingExportProjectJson = null
        val uri: Uri? = data?.data
        if (callback == null) return
        if (resultCode != Activity.RESULT_OK || uri == null) {
            callback.success(null)
            return
        }

        Thread {
            try {
                if (requestCode == PROJECT_IMPORT_REQUEST) {
                    val output = ByteArrayOutputStream()
                    contentResolver.openInputStream(uri)?.use { stream ->
                        val buffer = ByteArray(8192)
                        while (true) {
                            val count = stream.read(buffer)
                            if (count < 0) break
                            if (output.size() + count > MAX_PROJECT_BYTES) {
                                throw java.io.IOException("Project exceeds 24 MiB.")
                            }
                            output.write(buffer, 0, count)
                        }
                    } ?: throw java.io.IOException("Could not read selected project.")
                    val json = output.toString(Charsets.UTF_8.name())
                    runOnUiThread { callback.success(json) }
                } else {
                    if (exportJson == null) throw java.io.IOException("Export data was lost.")
                    contentResolver.openOutputStream(uri, "wt")?.use {
                        it.write(exportJson.toByteArray(Charsets.UTF_8))
                    } ?: throw java.io.IOException("Could not open export destination.")
                    runOnUiThread { callback.success(uri.toString()) }
                }
            } catch (error: Exception) {
                runOnUiThread { callback.error("project_file_failed", error.message, null) }
            }
        }.start()
    }

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

        // V10 periodically checkpoints XYZ data. Don't block the Android
        // main thread (and Flutter/AR interactions) on a large JSON write.
        // Write a temp file in the same directory, then atomically rename it,
        // preserving the last good draft if the process dies mid-save.
        Thread {
            val directory = mappingDirectory()
            val safeName = safeId(id)
            val file = File(directory, "$safeName.json")
            val temp = File(directory, ".$safeName.${System.nanoTime()}.tmp")
            try {
                temp.writeText(json, Charsets.UTF_8)
                if (!temp.renameTo(file)) {
                    throw java.io.IOException("Could not commit mapping checkpoint.")
                }
                runOnUiThread { result.success(file.absolutePath) }
            } catch (error: Exception) {
                temp.delete()
                runOnUiThread {
                    result.error("save_failed", error.message, null)
                }
            }
        }.start()
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
