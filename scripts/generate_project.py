"""Generate the fixed-identity Xcode project from checked-in source/resources."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
sources = sorted((root/'LeicaPhoto').glob('*.swift'))
models = sorted((root/'LeicaPhoto/Models').glob('*.mlpackage'))
resources = sorted(p for p in (root/'LeicaPhoto/Resources').iterdir() if p.is_file())
assets = root/'LeicaPhoto/Assets.xcassets'
if assets.exists(): resources.append(assets)
files = sources + models + resources
source_count = len(sources) + len(models)
def uid(n): return f'{n:024X}'
objects=[]
def obj(i,s):objects.append(f'{uid(i)} = {{ {s} }};')
for i,p in enumerate(files):
 kind='sourcecode.swift' if p.suffix=='.swift' else 'folder.mlpackage' if p.suffix=='.mlpackage' else 'folder.assetcatalog' if p.suffix=='.xcassets' else 'file'
 obj(100+i,f'isa = PBXFileReference; lastKnownFileType = {kind}; path = "{p.relative_to(root/"LeicaPhoto")}"; sourceTree = "<group>";')
 obj(400+i,f'isa = PBXBuildFile; fileRef = {uid(100+i)};')
obj(1,f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; }}; buildConfigurationList = {uid(10)}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = {uid(2)}; productRefGroup = {uid(4)}; projectDirPath = ""; targets = ({uid(5)});')
obj(2,f'isa = PBXGroup; children = ({uid(3)},{uid(4)}); sourceTree = "<group>";')
obj(3,f'isa = PBXGroup; children = ({",".join(uid(100+i) for i in range(len(files)))}); path = LeicaPhoto; sourceTree = "<group>";')
obj(4,f'isa = PBXGroup; children = ({uid(6)}); name = Products; sourceTree = "<group>";')
obj(6,'isa = PBXFileReference; explicitFileType = wrapper.application; path = LeicaPhoto.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj(5,f'isa = PBXNativeTarget; buildConfigurationList = {uid(11)}; buildPhases = ({uid(7)},{uid(8)},{uid(9)}); buildRules = (); dependencies = (); name = LeicaPhoto; productName = LeicaPhoto; productReference = {uid(6)}; productType = "com.apple.product-type.application";')
for i,kind,ids in [(7,'Sources',range(400,400+source_count)),(8,'Frameworks',[]),(9,'Resources',range(400+source_count,400+len(files)))]:obj(i,f'isa = PBX{kind}BuildPhase; buildActionMask = 2147483647; files = ({",".join(uid(x) for x in ids)}); runOnlyForDeploymentPostprocessing = 0;')
for i,ids in [(10,[12,13]),(11,[14,15])]:obj(i,f'isa = XCConfigurationList; buildConfigurations = ({",".join(uid(x) for x in ids)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
for i,name in [(12,'Debug'),(13,'Release')]:obj(i,f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; }};')
for i,name in [(14,'Debug'),(15,'Release')]:
 obj(i,f'''isa = XCBuildConfiguration; name = {name}; buildSettings = {{ PRODUCT_BUNDLE_IDENTIFIER = local.guangse.photo; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_CFBundleDisplayName = "光色"; INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription = "保存拍摄原片和处理后的照片到你的相册。"; INFOPLIST_KEY_NSCameraUsageDescription = "拍摄原片，并在设备本地生成滤镜照片。"; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"; INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"; TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 9; MARKETING_VERSION = 0.7.0; COREML_CODEGEN_LANGUAGE = Swift; ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; SWIFT_OPTIMIZATION_LEVEL = "{'-Onone' if name=='Debug' else '-O'}"; }};''')
(root/'LeicaPhoto.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {uid(1)}; }}\n')
print(f'{len(sources)} Swift files, {len(models)} Core ML models, {len(resources)} resource entries')
