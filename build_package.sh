#!/bin/bash

# Build script for photo2 app
# Creates an optimized build for Apple Silicon and exports as a .pkg file

set -e  # Exit on any error

# Configuration
PROJECT_NAME="photo2"
SCHEME_NAME="photo2"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/package"
ARCHIVE_PATH="${BUILD_DIR}/${PROJECT_NAME}.xcarchive"
EXPORT_PATH="${BUILD_DIR}"
APP_PATH="${EXPORT_PATH}/${PROJECT_NAME}.app"
PKG_PATH="${EXPORT_PATH}/${PROJECT_NAME}.pkg"

# Build settings for optimization
ARCHITECTURE="arm64"  # Apple Silicon
CONFIGURATION="Release"

echo "=========================================="
echo "Building ${PROJECT_NAME}"
echo "=========================================="
echo "Project Directory: ${PROJECT_DIR}"
echo "Output Directory: ${BUILD_DIR}"
echo "Architecture: ${ARCHITECTURE}"
echo "Configuration: ${CONFIGURATION}"
echo "=========================================="

# Clean previous build artifacts
echo ""
echo "Cleaning previous build artifacts..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Create a temporary export options plist for non-notarized distribution
EXPORT_OPTIONS_PLIST="${BUILD_DIR}/ExportOptions.plist"
cat > "${EXPORT_OPTIONS_PLIST}" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
EOF

# Build the archive with optimizations for Apple Silicon
echo ""
echo "Building archive with speed optimizations for Apple Silicon..."
xcodebuild archive \
    -project "${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME_NAME}" \
    -configuration "${CONFIGURATION}" \
    -archivePath "${ARCHIVE_PATH}" \
    -destination "generic/platform=macOS" \
    ARCHS="${ARCHITECTURE}" \
    ONLY_ACTIVE_ARCH=NO \
    VALID_ARCHS="${ARCHITECTURE}" \
    BUILD_LIBRARY_FOR_DISTRIBUTION=NO \
    SWIFT_OPTIMIZATION_LEVEL="-O" \
    GCC_OPTIMIZATION_LEVEL=3 \
    SWIFT_COMPILATION_MODE=wholemodule \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    | tee "${BUILD_DIR}/archive.log" | grep -E "^(Archive|Build|Compile|Link|Sign|error:|warning:|\*\*)"

# Check if archive was created
if [ ! -d "${ARCHIVE_PATH}" ]; then
    echo "Error: Archive was not created!"
    exit 1
fi

echo ""
echo "Archive created at: ${ARCHIVE_PATH}"

# Extract the .app from the archive
echo ""
echo "Extracting application from archive..."
cp -R "${ARCHIVE_PATH}/Products/Applications/${PROJECT_NAME}.app" "${APP_PATH}"

# Check if app was extracted
if [ ! -d "${APP_PATH}" ]; then
    echo "Error: App bundle was not extracted!"
    exit 1
fi

echo "App bundle created at: ${APP_PATH}"

# Create the .pkg installer using productbuild
echo ""
echo "Creating .pkg installer..."

# Create a simple component plist for the package
COMPONENT_PLIST="${BUILD_DIR}/component.plist"
pkgbuild --analyze --root "${APP_PATH}" "${COMPONENT_PLIST}" 2>/dev/null || true

# Build the pkg
pkgbuild \
    --root "${APP_PATH}" \
    --identifier "com.davxiao.photo2" \
    --version "1.0" \
    --install-location "/Applications/${PROJECT_NAME}.app" \
    "${BUILD_DIR}/${PROJECT_NAME}-component.pkg"

# Create a distribution package for better installation experience
DISTRIBUTION_XML="${BUILD_DIR}/distribution.xml"
cat > "${DISTRIBUTION_XML}" << EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>${PROJECT_NAME}</title>
    <organization>com.davxiao</organization>
    <domains enable_localSystem="true"/>
    <options customize="never" require-scripts="false" rootVolumeOnly="true"/>
    <choices-outline>
        <line choice="default">
            <line choice="${PROJECT_NAME}"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="${PROJECT_NAME}" visible="false">
        <pkg-ref id="com.davxiao.photo2"/>
    </choice>
    <pkg-ref id="com.davxiao.photo2" version="1.0" onConclusion="none">${PROJECT_NAME}-component.pkg</pkg-ref>
</installer-gui-script>
EOF

productbuild \
    --distribution "${DISTRIBUTION_XML}" \
    --package-path "${BUILD_DIR}" \
    "${PKG_PATH}"

# Clean up intermediate files
echo ""
echo "Cleaning up intermediate files..."
rm -f "${BUILD_DIR}/${PROJECT_NAME}-component.pkg"
rm -f "${COMPONENT_PLIST}"
rm -f "${DISTRIBUTION_XML}"
rm -f "${EXPORT_OPTIONS_PLIST}"

# Verify the final package
if [ -f "${PKG_PATH}" ]; then
    echo ""
    echo "=========================================="
    echo "Build completed successfully!"
    echo "=========================================="
    echo ""
    echo "Output files in ${BUILD_DIR}:"
    ls -lh "${BUILD_DIR}"
    echo ""
    echo "App Bundle: ${APP_PATH}"
    echo "Installer: ${PKG_PATH}"
    echo ""
    echo "To install, double-click the .pkg file or run:"
    echo "  sudo installer -pkg \"${PKG_PATH}\" -target /"
    echo ""
else
    echo "Error: Package was not created!"
    exit 1
fi
