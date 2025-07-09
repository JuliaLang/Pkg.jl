#!/usr/bin/env julia

# Test file for child progress bars functionality
# Run with: julia test_child_progress.jl

push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))
using MiniProgressBars

function test_child_progress_bars()
    # Create main progress bar
    main_bar = MiniProgressBar(
        header = "Downloading artifacts",
        color = :green,
        mode = :int,
        max = 5,
        current = 0,
        always_reprint = true,
        indent = 2
    )

    # Create child progress bars with different sizes and names
    child_bars = [
        MiniProgressBar(header = "large_dataset.tar.gz", mode = :data, max = 50_000_000, color = :blue),
        MiniProgressBar(header = "small_config.json", mode = :data, max = 1_500, color = :cyan),
        MiniProgressBar(header = "medium_lib.so", mode = :data, max = 2_500_000, color = :yellow),
        MiniProgressBar(header = "tiny_readme.txt", mode = :data, max = 800, color = :magenta),
        MiniProgressBar(header = "binary_tool", mode = :data, max = 12_000_000, color = :red),
    ]

    # Add children to main progress bar
    for child in child_bars
        add_child_progress(main_bar, child)
    end

    println("Testing child progress bars...")
    println("Press Ctrl+C to exit\n")

    # Create multi-progress display
    display = MultiProgressDisplay(main_bar, stdout)

    try
        # Simulate downloads with different speeds
        tasks = []
        for (i, child) in enumerate(child_bars)
            task = Threads.@spawn begin
                sleep_time = 0.05 + (i * 0.01)  # Different speeds

                for step in 1:100
                    # Calculate progress as percentage of max, ensuring we reach exactly max at step 100
                    progress = (step * child.max) ÷ 100
                    child.current = min(child.max, progress)
                    sleep(sleep_time)

                    # Add some status messages occasionally
                    if step == 20
                        child.status = "connecting..."
                    elseif step == 40
                        child.status = "downloading..."
                    elseif step == 80
                        child.status = "verifying..."
                    elseif step == 100
                        child.current = child.max  # Ensure we reach exactly max
                        child.status = "complete"
                        main_bar.current += 1
                        break
                    end
                end
            end
            push!(tasks, task)
        end

        # Start the multi-progress display
        display_task = start_multi_progress(display)

        # Wait for all tasks to complete
        for task in tasks
            wait(task)
        end

        # Stop the display
        stop_multi_progress(display, display_task)
        println("All downloads completed!")

    catch InterruptException
        println("\nInterrupted by user")
        if display.is_active
            stop_multi_progress(display, display_task)
        end
    end
end


if abspath(PROGRAM_FILE) == @__FILE__
    test_child_progress_bars()
end
