function generate_extension_name()
    # Extract the package name from the current environment
    pkgname = split.(keys(Base.loaded_modules))[end][1]
    # Remove any leading or trailing whitespace and replace dashes with underscores
    pkgname = replace(strip(pkgname), r"-" => "_")
    # Return the extension name
    return "$(pkgname)Ext"
end
