package com.firstmate.autonomy.ui.navigation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.firstmate.autonomy.ui.decisions.DecisionEditorScreen
import com.firstmate.autonomy.ui.decisions.DecisionListScreen
import com.firstmate.autonomy.ui.goals.GoalEditorRoute
import com.firstmate.autonomy.ui.goals.GoalListRoute
import com.firstmate.autonomy.ui.space.SpaceRoute
import com.firstmate.autonomy.ui.today.TodayRoute
import com.firstmate.autonomy.ui.you.YouRoute

/**
 * App shell: a bottom bar over a single [NavHost].
 *
 * The bar slides away on detail and editor routes rather than disappearing,
 * so a push reads as going deeper rather than as the chrome glitching.
 */
@Composable
fun AutonomyApp(
    modifier: Modifier = Modifier,
    navController: NavHostController = rememberNavController(),
) {
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = backStackEntry?.destination
    val isTopLevel = currentDestination?.hierarchy?.any { destination ->
        TopLevelDestination.entries.any { it.route == destination.route }
    } == true

    Scaffold(
        modifier = modifier.fillMaxSize(),
        containerColor = MaterialTheme.colorScheme.background,
        bottomBar = {
            AnimatedVisibility(
                visible = isTopLevel,
                enter = slideInVertically(tween(240)) { it },
                exit = slideOutVertically(tween(200)) { it },
            ) {
                NavigationBar(
                    containerColor = MaterialTheme.colorScheme.surfaceContainer,
                ) {
                    TopLevelDestination.entries.forEach { destination ->
                        val selected = currentDestination
                            ?.hierarchy
                            ?.any { it.route == destination.route } == true
                        NavigationBarItem(
                            selected = selected,
                            onClick = { navController.navigateToTopLevel(destination) },
                            icon = {
                                Icon(
                                    imageVector = if (selected) {
                                        destination.selectedIcon
                                    } else {
                                        destination.unselectedIcon
                                    },
                                    contentDescription = null,
                                )
                            },
                            // Five tabs on a phone leave roughly 70dp each.
                            // The default label style overruns that and gets
                            // clipped, so the label is stepped down a size and
                            // pinned to one line.
                            label = {
                                Text(
                                    text = destination.label,
                                    style = MaterialTheme.typography.labelSmall,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            },
                            colors = NavigationBarItemDefaults.colors(
                                selectedIconColor = MaterialTheme.colorScheme.onPrimaryContainer,
                                selectedTextColor = MaterialTheme.colorScheme.primary,
                                indicatorColor = MaterialTheme.colorScheme.primaryContainer,
                                unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
                                unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            ),
                        )
                    }
                }
            }
        },
    ) { innerPadding ->
        AutonomyNavHost(
            navController = navController,
            modifier = Modifier.padding(innerPadding),
        )
    }
}

@Composable
private fun AutonomyNavHost(
    navController: NavHostController,
    modifier: Modifier = Modifier,
) {
    NavHost(
        navController = navController,
        startDestination = Routes.SPACE,
        modifier = modifier,
        // Tabs cross-fade; the push/pop pairs below override this per route.
        enterTransition = { tabEnter() },
        exitTransition = { tabExit() },
        popEnterTransition = { tabEnter() },
        popExitTransition = { tabExit() },
    ) {
        composable(Routes.SPACE) {
            SpaceRoute(onOpenGoal = { navController.navigate(Routes.goalEditor(it)) })
        }

        composable(Routes.TODAY) {
            TodayRoute(onOpenGoal = { navController.navigate(Routes.goalEditor(it)) })
        }

        composable(Routes.GOAL_LIST) {
            GoalListRoute(
                onOpenGoal = { navController.navigate(Routes.goalEditor(it)) },
                onNewGoal = { navController.navigate(Routes.goalEditor()) },
            )
        }

        composable(
            route = Routes.GOAL_EDITOR,
            arguments = listOf(
                navArgument(ARG_GOAL_ID) {
                    type = NavType.LongType
                    defaultValue = NO_ID
                },
            ),
            enterTransition = { pushEnter() },
            exitTransition = { pushExit() },
            popEnterTransition = { popEnter() },
            popExitTransition = { popExit() },
        ) {
            GoalEditorRoute(onDone = { navController.popBackStack() })
        }

        composable(Routes.DECISION_LIST) {
            DecisionListScreen(
                onDecisionClick = { navController.navigate(Routes.decisionEditor(it)) },
                onCreateDecision = { navController.navigate(Routes.decisionEditor()) },
            )
        }

        composable(
            route = Routes.DECISION_EDITOR,
            arguments = listOf(
                navArgument(ARG_DECISION_ID) {
                    type = NavType.LongType
                    defaultValue = NO_ID
                },
            ),
            enterTransition = { pushEnter() },
            exitTransition = { pushExit() },
            popEnterTransition = { popEnter() },
            popExitTransition = { popExit() },
        ) {
            DecisionEditorScreen(onNavigateBack = { navController.popBackStack() })
        }

        composable(Routes.YOU) { YouRoute() }
    }
}

/**
 * Tab switching: single top, state preserved per tab, and the back stack always
 * unwinds to the dashboard rather than through every tab visited.
 */
private fun NavHostController.navigateToTopLevel(destination: TopLevelDestination) {
    navigate(destination.route) {
        popUpTo(graph.findStartDestination().id) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}
