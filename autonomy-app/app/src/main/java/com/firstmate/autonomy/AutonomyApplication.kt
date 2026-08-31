package com.firstmate.autonomy

import android.app.Application
import com.firstmate.autonomy.di.AppContainer
import com.firstmate.autonomy.di.DefaultAppContainer

/** Owns the app-wide dependency graph for the process lifetime. */
class AutonomyApplication : Application() {

    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = DefaultAppContainer(this)
    }
}
