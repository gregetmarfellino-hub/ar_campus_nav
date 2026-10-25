package com.example.ar_campus_nav

import android.graphics.Bitmap
import android.opengl.GLES20
import android.opengl.GLUtils
import android.opengl.Matrix
import com.google.ar.core.Camera
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * Renders a textured square QR billboard at an arbitrary world-space pose.
 * The billboard is defined by a center point plus world-space right/up axes,
 * so placement is not tied to ARCore plane detection.
 */
class ArQrPlacementPreviewRenderer {
    private var program = 0
    private var positionAttrib = 0
    private var texCoordAttrib = 0
    private var mvpUniform = 0
    private var textureUniform = 0
    private var textureId = 0

    private var pendingBitmap: Bitmap? = null

    private val positions: FloatBuffer = ByteBuffer
        .allocateDirect(4 * 3 * 4)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()

    private val texCoords: FloatBuffer = ByteBuffer
        .allocateDirect(4 * 2 * 4)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()
        .apply {
            put(
                floatArrayOf(
                    0f, 1f,
                    1f, 1f,
                    1f, 0f,
                    0f, 0f,
                ),
            )
            position(0)
        }

    fun createOnGlThread() {
        val vertex = """
            uniform mat4 u_Mvp;
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            void main() {
                gl_Position = u_Mvp * vec4(a_Position, 1.0);
                v_TexCoord = a_TexCoord;
            }
        """.trimIndent()

        val fragment = """
            precision mediump float;
            uniform sampler2D u_Texture;
            varying vec2 v_TexCoord;
            void main() {
                gl_FragColor = texture2D(u_Texture, v_TexCoord);
            }
        """.trimIndent()

        program = ArCameraBackgroundRenderer.createProgram(vertex, fragment)
        positionAttrib = GLES20.glGetAttribLocation(program, "a_Position")
        texCoordAttrib = GLES20.glGetAttribLocation(program, "a_TexCoord")
        mvpUniform = GLES20.glGetUniformLocation(program, "u_Mvp")
        textureUniform = GLES20.glGetUniformLocation(program, "u_Texture")
    }

    fun setBitmap(bitmap: Bitmap?) {
        pendingBitmap = bitmap
    }

    fun draw(
        camera: Camera,
        center: FloatArray,
        rightAxis: FloatArray,
        upAxis: FloatArray,
        sizeMeters: Float,
    ) {
        if (program == 0 || center.size < 3 || sizeMeters <= 0f) return
        ensureTexture()
        if (textureId == 0) return

        val half = sizeMeters * 0.5f
        val rx = rightAxis[0] * half
        val ry = rightAxis[1] * half
        val rz = rightAxis[2] * half
        val ux = upAxis[0] * half
        val uy = upAxis[1] * half
        val uz = upAxis[2] * half

        positions.clear()
        positions.put(
            floatArrayOf(
                center[0] - rx - ux,
                center[1] - ry - uy,
                center[2] - rz - uz,

                center[0] + rx - ux,
                center[1] + ry - uy,
                center[2] + rz - uz,

                center[0] + rx + ux,
                center[1] + ry + uy,
                center[2] + rz + uz,

                center[0] - rx + ux,
                center[1] - ry + uy,
                center[2] - rz + uz,
            ),
        )
        positions.position(0)

        val view = FloatArray(16)
        val projection = FloatArray(16)
        val mvp = FloatArray(16)
        camera.getViewMatrix(view, 0)
        camera.getProjectionMatrix(projection, 0, 0.05f, 100f)
        Matrix.multiplyMM(mvp, 0, projection, 0, view, 0)

        GLES20.glUseProgram(program)
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        GLES20.glUniformMatrix4fv(mvpUniform, 1, false, mvp, 0)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
        GLES20.glUniform1i(textureUniform, 0)

        GLES20.glEnableVertexAttribArray(positionAttrib)
        GLES20.glVertexAttribPointer(
            positionAttrib,
            3,
            GLES20.GL_FLOAT,
            false,
            0,
            positions,
        )

        texCoords.position(0)
        GLES20.glEnableVertexAttribArray(texCoordAttrib)
        GLES20.glVertexAttribPointer(
            texCoordAttrib,
            2,
            GLES20.GL_FLOAT,
            false,
            0,
            texCoords,
        )

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_FAN, 0, 4)

        GLES20.glDisableVertexAttribArray(positionAttrib)
        GLES20.glDisableVertexAttribArray(texCoordAttrib)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        GLES20.glDisable(GLES20.GL_BLEND)
    }

    fun release() {
        if (textureId != 0) {
            val ids = intArrayOf(textureId)
            GLES20.glDeleteTextures(1, ids, 0)
            textureId = 0
        }
        pendingBitmap = null
    }

    private fun ensureTexture() {
        val bitmap = pendingBitmap ?: return

        if (textureId == 0) {
            val ids = IntArray(1)
            GLES20.glGenTextures(1, ids, 0)
            textureId = ids[0]
        }

        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D,
            GLES20.GL_TEXTURE_MIN_FILTER,
            GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D,
            GLES20.GL_TEXTURE_MAG_FILTER,
            GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D,
            GLES20.GL_TEXTURE_WRAP_S,
            GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D,
            GLES20.GL_TEXTURE_WRAP_T,
            GLES20.GL_CLAMP_TO_EDGE,
        )
        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)

        pendingBitmap = null
    }
}
