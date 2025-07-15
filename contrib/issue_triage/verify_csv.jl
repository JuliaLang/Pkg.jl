#!/usr/bin/env julia

"""
Quick verification script for the generated CSV
"""

using CSV, DataFrames

# Read the CSV
df = CSV.read("pkg_issues.csv", DataFrame)

println("📊 CSV File Analysis")
println("=" ^ 50)
println("Total issues: $(nrow(df))")
println("Number of columns: $(ncol(df))")
println("\nColumn names:")
for (i, col) in enumerate(names(df))
    println("  $i. $col")
end

println("\n🏷️ Sample of recent issues:")
println("=" ^ 50)
recent = first(df, 5)
for row in eachrow(recent)
    println("Issue #$(row.number): $(row.title)")
    labels_str = ismissing(row.labels) || isempty(row.labels) ? "None" : row.labels
    author_str = ismissing(row.author) ? "Unknown" : row.author
    println("  Author: $(author_str), Labels: $(labels_str)")
    println("  Created: $(row.created_at), Updated: $(row.updated_at)")
    println("  Age: $(row.age_days) days, Comments: $(row.comments_count)")
    println()
end

println("📈 Quick Statistics:")
println("=" ^ 50)
println("Oldest issue: $(maximum(df.age_days)) days old")
println("Newest issue: $(minimum(df.age_days)) days old")
println("Most commented issue: $(maximum(df.comments_count)) comments")
println("Most reacted to issue: $(maximum(df.reactions_total)) reactions")
println("Issues with labels: $(count(x -> !ismissing(x) && !isempty(x), df.labels))")
println("Issues with assignees: $(count(x -> !ismissing(x) && !isempty(x), df.assignees))")
