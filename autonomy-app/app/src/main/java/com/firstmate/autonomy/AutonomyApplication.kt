package com.firstmate.autonomy

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

/**
 * Hilt generates the application component from this annotation; the graph is
 * validated at compile time, so a missing binding is a build failure rather
 * than a crash on first launch.
 */
@HiltAndroidApp
class AutonomyApplication : Application()
