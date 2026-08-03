package com.calliopeia.sample

import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.withContentDescription
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MainActivityTest {
    @Test
    fun primaryWorkflowIsVisible() {
        ActivityScenario.launch(MainActivity::class.java).use {
            onView(withContentDescription("GraphQL endpoint")).check(matches(isDisplayed()))
            onView(withContentDescription("録音開始")).check(matches(isDisplayed()))
            onView(withContentDescription("停止・送信")).check(matches(isDisplayed()))
            onView(withContentDescription("ジョブ状態")).check(matches(isDisplayed()))
        }
    }
}
