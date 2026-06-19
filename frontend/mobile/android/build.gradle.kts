allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// objectbox_flutter_libs 4.3.1 (pulled in by flutter_map_tile_caching) hardcodes
// compileSdkVersion 31 in its own module, which is too low for its current
// transitive androidx deps (fragment 1.7.1 etc want >=34). FMTC pins objectbox
// to ^4.1.0 so we can't just bump past the major version. Force every plugin
// subproject's compileSdk to match the app's, regardless of what the plugin
// itself declares. Must run before evaluationDependsOn below forces eager
// evaluation, or afterEvaluate throws "project already evaluated".
subprojects {
    afterEvaluate {
        extensions.findByType<com.android.build.gradle.BaseExtension>()?.apply {
            compileSdkVersion(36)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
