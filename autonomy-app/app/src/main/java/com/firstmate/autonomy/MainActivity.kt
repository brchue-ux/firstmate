package com.firstmate.autonomy

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
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
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent { AutonomyRoot() }
    }
}

@Composable
private fun AutonomyRoot(darkTheme: Boolean = isSystemInDarkTheme()) {
    AutonomyTheme(darkTheme = darkTheme) {
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background,
        ) {
            AutonomyApp()
        }
    }
}
