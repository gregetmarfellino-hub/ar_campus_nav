package com.example.ar_campus_nav

import android.opengl.GLES11Ext
import android.opengl.GLES20
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

class ArCameraBackgroundRenderer {
    private val quadCoords = floatBuffer(
        floatArrayOf(
            -1f, -1f,
             1f, -1f,
            -1f,  1f,
             1f,  1f,
        ),
    )

    private val transformedTexCoords = floatBuffer(FloatArray(8))
    private var program = 0
    private var positionAttrib = 0
    private var texAttrib = 0
    private var textureUniform = 0

    fun createOnGlThread() {
        val vertex = """
            attribute vec2 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            void main() {
                gl_Position = vec4(a_Position, 0.0, 1.0);
                v_TexCoord = a_TexCoord;
            }
        """.trimIndent()

        val fragment = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            uniform samplerExternalOES u_Texture;
            varying vec2 v_TexCoord;
            void main() {
                gl_FragColor = texture2D(u_Texture, v_TexCoord);
            }
        """.trimIndent()

        program = createProgram(vertex, fragment)
        positionAttrib = GLES20.glGetAttribLocation(program, "a_Position")
        texAttrib = GLES20.glGetAttribLocation(program, "a_TexCoord")
        textureUniform = GLES20.glGetUniformLocation(program, "u_Texture")
    }

    fun draw(frame: Frame, cameraTextureId: Int) {
        if (program == 0 || cameraTextureId == 0) return

        quadCoords.position(0)
        transformedTexCoords.position(0)

        frame.transformCoordinates2d(
            Coordinates2d.OPENGL_NORMALIZED_DEVICE_COORDINATES,
            quadCoords,
            Coordinates2d.TEXTURE_NORMALIZED,
            transformedTexCoords,
        )

        quadCoords.position(0)
        transformedTexCoords.position(0)

        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glDepthMask(false)
        GLES20.glUseProgram(program)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            cameraTextureId,
        )
        GLES20.glUniform1i(textureUniform, 0)

        GLES20.glEnableVertexAttribArray(positionAttrib)
        GLES20.glVertexAttribPointer(
            positionAttrib,
            2,
            GLES20.GL_FLOAT,
            false,
            0,
            quadCoords,
        )

        GLES20.glEnableVertexAttribArray(texAttrib)
        GLES20.glVertexAttribPointer(
            texAttrib,
            2,
            GLES20.GL_FLOAT,
            false,
            0,
            transformedTexCoords,
        )

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(positionAttrib)
        GLES20.glDisableVertexAttribArray(texAttrib)
        GLES20.glDepthMask(true)
    }

    companion object {
        fun createProgram(vertexSource: String, fragmentSource: String): Int {
            val vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, vertexSource)
            val fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSource)
            return GLES20.glCreateProgram().also { program ->
                GLES20.glAttachShader(program, vertexShader)
                GLES20.glAttachShader(program, fragmentShader)
                GLES20.glLinkProgram(program)
            }
        }

        private fun compileShader(type: Int, source: String): Int {
            return GLES20.glCreateShader(type).also { shader ->
                GLES20.glShaderSource(shader, source)
                GLES20.glCompileShader(shader)
            }
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
}
