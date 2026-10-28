package com.example.ar_campus_nav

import android.opengl.GLES20
import android.opengl.Matrix
import com.google.ar.core.Camera
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

class ArBreadcrumbRenderer {
    private var program = 0
    private var positionAttrib = 0
    private var mvpUniform = 0
    private var colorUniform = 0
    private var pointSizeUniform = 0
    private var pointModeUniform = 0

    fun createOnGlThread() {
        val vertex = """
            uniform mat4 u_Mvp;
            uniform float u_PointSize;
            attribute vec3 a_Position;
            void main() {
                gl_Position = u_Mvp * vec4(a_Position, 1.0);
                gl_PointSize = u_PointSize;
            }
        """.trimIndent()

        val fragment = """
            precision mediump float;
            uniform vec4 u_Color;
            uniform int u_PointMode;
            void main() {
                if (u_PointMode == 1) {
                    vec2 d = gl_PointCoord - vec2(0.5);
                    if (dot(d, d) > 0.25) discard;
                }
                gl_FragColor = u_Color;
            }
        """.trimIndent()

        program = ArCameraBackgroundRenderer.createProgram(vertex, fragment)
        positionAttrib = GLES20.glGetAttribLocation(program, "a_Position")
        mvpUniform = GLES20.glGetUniformLocation(program, "u_Mvp")
        colorUniform = GLES20.glGetUniformLocation(program, "u_Color")
        pointSizeUniform = GLES20.glGetUniformLocation(program, "u_PointSize")
        pointModeUniform = GLES20.glGetUniformLocation(program, "u_PointMode")
    }

    fun draw(
        camera: Camera,
        worldPoints: List<FloatArray>,
        activeIndex: Int,
        userWorldPoint: FloatArray? = null,
    ) {
        if (program == 0 || worldPoints.isEmpty()) return

        val view = FloatArray(16)
        val projection = FloatArray(16)
        val mvp = FloatArray(16)

        camera.getViewMatrix(view, 0)
        camera.getProjectionMatrix(projection, 0, 0.05f, 100f)
        Matrix.multiplyMM(mvp, 0, projection, 0, view, 0)

        val start = activeIndex.coerceIn(0, worldPoints.lastIndex)
        val remaining = worldPoints.subList(start, worldPoints.size)
        val values = FloatArray(remaining.size * 3)

        for (i in remaining.indices) {
            val p = remaining[i]
            values[i * 3] = p[0]
            values[i * 3 + 1] = p[1]
            values[i * 3 + 2] = p[2]
        }

        val buffer = floatBuffer(values)

        GLES20.glUseProgram(program)
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        GLES20.glUniformMatrix4fv(mvpUniform, 1, false, mvp, 0)

        GLES20.glEnableVertexAttribArray(positionAttrib)
        GLES20.glVertexAttribPointer(
            positionAttrib,
            3,
            GLES20.GL_FLOAT,
            false,
            0,
            buffer,
        )

        // Live connector: makes the route visibly begin at the user's
        // current horizontal ARCore position instead of appearing to spawn
        // at the next routing node a few meters ahead.
        if (userWorldPoint != null && remaining.isNotEmpty()) {
            val connectorRibbon = routeRibbon(
                listOf(userWorldPoint, remaining.first()), 0.055f,
            )
            if (connectorRibbon != null) {
                GLES20.glVertexAttribPointer(
                    positionAttrib, 3, GLES20.GL_FLOAT, false, 0, connectorRibbon,
                )
                GLES20.glUniform4f(colorUniform, 0.45f, 0.91f, 1.0f, 0.80f)
                GLES20.glUniform1i(pointModeUniform, 0)
                GLES20.glDrawArrays(
                    GLES20.GL_TRIANGLES, 0, connectorRibbon.limit() / 3,
                )
            }

            val connectorValues = floatArrayOf(
                userWorldPoint[0],
                userWorldPoint[1],
                userWorldPoint[2],
                remaining.first()[0],
                remaining.first()[1],
                remaining.first()[2],
            )
            val connectorBuffer = floatBuffer(connectorValues)

            GLES20.glVertexAttribPointer(
                positionAttrib,
                3,
                GLES20.GL_FLOAT,
                false,
                0,
                connectorBuffer,
            )
            GLES20.glUniform4f(colorUniform, 0.78f, 0.88f, 1.0f, 0.88f)
            GLES20.glUniform1f(pointSizeUniform, 1f)
            GLES20.glUniform1i(pointModeUniform, 0)
            GLES20.glLineWidth(5f)
            GLES20.glDrawArrays(GLES20.GL_LINES, 0, 2)

            GLES20.glUniform4f(colorUniform, 0.78f, 0.88f, 1.0f, 1.0f)
            GLES20.glUniform1f(pointSizeUniform, 26f)
            GLES20.glUniform1i(pointModeUniform, 1)
            GLES20.glDrawArrays(GLES20.GL_POINTS, 0, 1)

            // Restore the route buffer for the remaining draws.
            buffer.position(0)
            GLES20.glVertexAttribPointer(
                positionAttrib,
                3,
                GLES20.GL_FLOAT,
                false,
                0,
                buffer,
            )
        }

        // Real metric-width 3D ribbon: GLES20.GL_LINE_STRIP widths above 1px
        // are not guaranteed on Android. Triangles stay visible on every GPU.
        val ribbon = routeRibbon(remaining, 0.09f)
        if (ribbon != null) {
            GLES20.glVertexAttribPointer(
                positionAttrib, 3, GLES20.GL_FLOAT, false, 0, ribbon,
            )
            GLES20.glUniform4f(colorUniform, 0.18f, 0.67f, 1.0f, 0.90f)
            GLES20.glUniform1i(pointModeUniform, 0)
            GLES20.glDrawArrays(
                GLES20.GL_TRIANGLES, 0, ribbon.limit() / 3,
            )
            buffer.position(0)
            GLES20.glVertexAttribPointer(
                positionAttrib, 3, GLES20.GL_FLOAT, false, 0, buffer,
            )
        }

        // Thin centerline on top of the ribbon, mainly for turns.
        GLES20.glUniform4f(colorUniform, 0.80f, 0.96f, 1.0f, 0.95f)
        GLES20.glUniform1f(pointSizeUniform, 1f)
        GLES20.glUniform1i(pointModeUniform, 0)
        GLES20.glLineWidth(1f)
        GLES20.glDrawArrays(GLES20.GL_LINE_STRIP, 0, remaining.size)

        // Sparse future breadcrumbs. The full route geometry remains in the
        // line strip above; dots are presentation-only and are decimated to
        // roughly one every 1.5 m so dense recorded samples do not clutter AR.
        val sparse = sparseBreadcrumbs(remaining, 1.5f)
        if (sparse.isNotEmpty()) {
            val sparseValues = FloatArray(sparse.size * 3)
            for (i in sparse.indices) {
                val p = sparse[i]
                sparseValues[i * 3] = p[0]
                sparseValues[i * 3 + 1] = p[1]
                sparseValues[i * 3 + 2] = p[2]
            }
            val sparseBuffer = floatBuffer(sparseValues)
            GLES20.glVertexAttribPointer(
                positionAttrib,
                3,
                GLES20.GL_FLOAT,
                false,
                0,
                sparseBuffer,
            )
            GLES20.glUniform4f(colorUniform, 0.30f, 0.72f, 1.0f, 0.72f)
            GLES20.glUniform1f(pointSizeUniform, 13f)
            GLES20.glUniform1i(pointModeUniform, 1)
            GLES20.glDrawArrays(GLES20.GL_POINTS, 0, sparse.size)

            // Restore the full route buffer for target/destination draws.
            buffer.position(0)
            GLES20.glVertexAttribPointer(
                positionAttrib,
                3,
                GLES20.GL_FLOAT,
                false,
                0,
                buffer,
            )
        }

        // Next target is green and larger.
        GLES20.glUniform4f(colorUniform, 0.24f, 0.86f, 0.59f, 1.0f)
        GLES20.glUniform1f(pointSizeUniform, 36f)
        GLES20.glDrawArrays(GLES20.GL_POINTS, 0, 1)

        // Final destination is larger and pink so it reads differently
        // from intermediate breadcrumbs.
        if (remaining.size > 1) {
            GLES20.glUniform4f(colorUniform, 1.0f, 0.42f, 0.60f, 1.0f)
            GLES20.glUniform1f(pointSizeUniform, 46f)
            GLES20.glDrawArrays(
                GLES20.GL_POINTS,
                remaining.size - 1,
                1,
            )
        }

        GLES20.glDisableVertexAttribArray(positionAttrib)
        GLES20.glDisable(GLES20.GL_BLEND)
    }

    // Produces 2 horizontal triangles per segment. Each segment has a
    // physical width in meters, independent of the driver's GL line support.
    private fun routeRibbon(
        points: List<FloatArray>,
        halfWidthMeters: Float,
    ): FloatBuffer? {
        if (points.size < 2) return null
        val vertices = ArrayList<Float>((points.size - 1) * 18)
        for (i in 0 until points.lastIndex) {
            val a = points[i]
            val b = points[i + 1]
            val dx = b[0] - a[0]
            val dz = b[2] - a[2]
            val length = kotlin.math.sqrt(dx * dx + dz * dz)
            if (length < 0.001f) continue

            // Perpendicular to the route on the horizontal ground plane.
            val ox = -dz / length * halfWidthMeters
            val oz = dx / length * halfWidthMeters
            val ay = a[1] + 0.015f
            val by = b[1] + 0.015f

            fun vertex(x: Float, y: Float, z: Float) {
                vertices.add(x)
                vertices.add(y)
                vertices.add(z)
            }

            // Winding is irrelevant because face culling is disabled for AR.
            vertex(a[0] + ox, ay, a[2] + oz)
            vertex(a[0] - ox, ay, a[2] - oz)
            vertex(b[0] + ox, by, b[2] + oz)

            vertex(b[0] + ox, by, b[2] + oz)
            vertex(a[0] - ox, ay, a[2] - oz)
            vertex(b[0] - ox, by, b[2] - oz)
        }
        return if (vertices.isEmpty()) null else floatBuffer(vertices.toFloatArray())
    }

    private fun sparseBreadcrumbs(
        points: List<FloatArray>,
        spacingMeters: Float,
    ): List<FloatArray> {
        if (points.size <= 2) return emptyList()

        val result = ArrayList<FloatArray>()
        var lastKept = points.first()

        // Skip index 0 because the current target is rendered separately.
        // Skip the final point because the destination is rendered separately.
        for (i in 1 until points.lastIndex) {
            val point = points[i]
            val dx = point[0] - lastKept[0]
            val dy = point[1] - lastKept[1]
            val dz = point[2] - lastKept[2]
            val distance = kotlin.math.sqrt(dx * dx + dy * dy + dz * dz)

            if (distance >= spacingMeters) {
                result.add(point)
                lastKept = point
            }
        }

        return result
    }

    private fun floatBuffer(values: FloatArray): FloatBuffer {
        return ByteBuffer
            .allocateDirect(values.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply {
                put(values)
                position(0)
            }
    }
}
