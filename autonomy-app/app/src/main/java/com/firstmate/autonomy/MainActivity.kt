package com.firstmate.autonomy

import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.firstmate.autonomy.ui.navigation.AutonomyApp
import com.firstmate.autonomy.ui.theme.AutonomyTheme
import dagger.hilt.android.AndroidEntryPoint

/** The app's single activity. Everything else is Compose. */
@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        // The app is obsidian regardless of the system setting, so the bar
        // icons must be light in every configuration. Bare enableEdgeToEdge()
        // picks them from the system's dark-mode flag, which puts dark icons on
        // a near-black background on a phone set to light - invisible.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        setContent { AutonomyRoot() }
    }
}

@Composable
private fun AutonomyRoot() {
    AutonomyTheme {
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background,
        ) {
            AutonomyApp()
        }
    }
}
