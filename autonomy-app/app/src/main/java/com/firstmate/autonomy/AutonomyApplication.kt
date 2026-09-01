package com.firstmate.autonomy

import android.app.Application
import com.firstmate.autonomy.domain.usecase.SeedStarterGoalsUseCase
import dagger.hilt.android.HiltAndroidApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Hilt generates the application component from this annotation; the graph is
 * validated at compile time, so a missing binding is a build failure rather
 * than a crash on first launch.
 */
@HiltAndroidApp
class AutonomyApplication : Application() {

    @Inject
    lateinit var seedStarterGoals: SeedStarterGoalsUseCase

    /**
     * Outlives any screen, because seeding must finish even if the first
     * activity is dismissed a second after launch. SupervisorJob so a failure
     * here can never take the process down - an empty sky is a poor first
     * minute, not a reason to crash.
     */
    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() {
        super.onCreate()
        applicationScope.launch {
            runCatching { seedStarterGoals() }
        }
    }
}
