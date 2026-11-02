/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file android_main.cpp Program entry point for Android. */

#include "../../stdafx.h"
#include "../../openttd.h"
#include "../../crashlog.h"
#include "../../core/random_func.hpp"
#include "../../string_func.h"

#include <SDL_main.h>
#include <ctime>
#include <signal.h>

#include "../../safeguards.h"

/**
 * Entry point called by SDLActivity through SDL's Java glue.
 *
 * Android never starts an executable: SDL's Java side loads the game library
 * and looks up "SDL_main" in it, so this is where the game begins.  By the time
 * it is called the activity already exists, which is what makes the
 * SDL_AndroidGet* getters usable.  The activity has also already created the
 * writable directories the game needs and exported them through the
 * environment, so openttd_main()'s base-path detection finds them.
 *
 * SDL synthesises an argv[0] of "app_process" for PHYSFS's benefit; OpenTTD
 * never looks at argv[0] beyond skipping it, so that value is left alone.
 */
extern "C" int SDL_main(int argc, char *argv[])
{
	/* Make sure our arguments contain only valid UTF-8 characters. */
	std::vector<std::string_view> params;
	params.reserve(argc);
	for (int i = 0; i < argc; ++i) {
		StrMakeValidInPlace(argv[i]);
		params.emplace_back(argv[i]);
	}

	CrashLog::InitialiseCrashLog();

	SetRandomSeed(time(nullptr));

	signal(SIGPIPE, SIG_IGN);

	int status = openttd_main(params);

	/* openttd_main() has run to completion, which on Android means the user
	 * chose to leave the game. Unlike a desktop build, this is not a process
	 * boundary: returning from SDL_main only stops the SDL thread, the
	 * process (and OpenTTD's global state, its sound subsystem, its window,
	 * and the asset manager it holds) keeps living underneath the launcher.
	 * A second SDL_main() -- which is what launch the next time produces,
	 * since the activity is never torn down -- would then restart the game
	 * inside that half-finished process feared to be running twice and
	 * crash on stale state.
	 *
	 * Ending the process here makes the next launch start a fresh, clean
	 * process, which is exactly the first-launch path that is known to work.
	 * SDL's own comment in nativeRunMain() -- "Do not issue an exit or the
	 * whole application will terminate" -- is about the SDL thread returning
	 * while the app is merely paused or backgrounded, not about this
	 * terminal quit. We are done with the app, so the whole process is the
	 * right thing to terminate. */
	std::_Exit(status);
}
