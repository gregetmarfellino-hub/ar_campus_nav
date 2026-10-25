package com.example.ar_campus_nav

import android.opengl.GLES20
import android.opengl.Matrix
import com.google.ar.core.Camera
import com.google.ar.core.Pose
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * Renders a simple metric square in the local X/Z plane of an ARCore wall-hit
 * pose. ARCore vertical planes use local Y as the plane normal, so this reads
 * as an upright 16 cm poster attached to the detected wall.
 */
class ArWallQrPreviewRenderer {
    private var program = 0
    private var positionAttrib = 0
    private var mvpUniform = 0
    private var colorUniform = 0

    private val quad: FloatBuffer = ByteBuffer
        .allocateDirect(4 * 3 * 4)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()
        .apply {
            put(
                floatArrayOf(
                    -0.5f, 0f, -0.5f,
                    0.5f, 0f, -0.5f,
                    0.5f, 0f, 0.5f,
                    -0.5f, 0f, 0.5f,
                ),
            )
            position(0)
        }

    fun createOnGlThread() {
        val vertex = """
            uniform mat4 u_Mvp;
            attribute vec3 a_Position;
            void main() {
                gl_Position = u_Mvp * vec4(a_Position, 1.0);
            }
        """.trimIndent()

        val fragment = """
            precision mediump float;
            uniform vec4 u_Color;
            void main() {
                gl_FragColor = u_Color;
            }
        """.trimIndent()

        program = ArCameraBackgroundRenderer.createProgram(vertex, fragment)
        positionAttrib = GLES20.glGetAttribLocation(program, "a_Position")
        mvpUniform = GLES20.glGetUniformLocation(program, "u_Mvp")
        colorUniform = GLES20.glGetUniformLocation(program, "u_Color")
    }

    fun draw(
        camera: Camera,
        pose: Pose,
        sizeMeters: Float,
    ) {
        if (program == 0 || sizeMeters <= 0f) return

        val model = FloatArray(16)
        val view = FloatArray(16)
        val projection = FloatArray(16)
        val viewModel = FloatArray(16)
        val mvp = FloatArray(16)

        pose.toMatrix(model, 0)
        Matrix.scaleM(model, 0, sizeMeters, sizeMeters, sizeMeters)
        camera.getViewMatrix(view, 0)
        camera.getProjectionMatrix(projection, 0, 0.05f, 100f)
        Matrix.multiplyMM(viewModel, 0, view, 0, model, 0)
        Matrix.multiplyMM(mvp, 0, projection, 0, viewModel, 0)

        GLES20.glUseProgram(program)
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        GLES20.glUniformMatrix4fv(mvpUniform, 1, false, mvp, 0)

        quad.position(0)
        GLES20.glEnableVertexAttribArray(positionAttrib)
        GLES20.glVertexAttribPointer(
            positionAttrib,
            3,
            GLES20.GL_FLOAT,
            false,
            0,
            quad,
        )

        // Translucent poster body.
        GLES20.glUniform4f(colorUniform, 0.24f, 0.86f, 0.59f, 0.28f)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_FAN, 0, 4)

        // Bright outline makes the 16 cm physical footprint obvious.
        GLES20.glUniform4f(colorUniform, 0.24f, 0.86f, 0.59f, 1.0f)
        GLES20.glLineWidth(6f)
        GLES20.glDrawArrays(GLES20.GL_LINE_LOOP, 0, 4)

        GLES20.glDisableVertexAttribArray(positionAttrib)
        GLES20.glDisable(GLES20.GL_BLEND)
    }
}
