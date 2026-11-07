#!/usr/bin/env python3
from hashlib import sha1
from pathlib import Path
root=Path(__file__).resolve().parent.parent
p=root/'AetherXR.xcodeproj';p.mkdir(exist_ok=True)
files=sorted(path.name for path in (root/'AetherXR').glob('*.swift'))
def ident(name):return sha1(name.encode()).hexdigest()[:24].upper()
def link(item, comment=None):return f'{ident(item)} /* {comment or item} */'
def block(obj):return '\n'.join(obj)
b=[]
b.extend(['// !$*UTF8*$!', '{', '\tarchiveVersion = 1;', '\tclasses = {};', '\tobjectVersion = 56;', '\tobjects = {'])
# Build file records
b.append('\n/* Begin PBXBuildFile section */')
for fname in files:
 b.append(f'\t\t{link("build:"+fname,fname+" in Sources")} = {{isa = PBXBuildFile; fileRef = {link("file:"+fname,fname)}; }};')
b.append(f'\t\t{link("build:assets","Assets.xcassets in Resources")} = {{isa = PBXBuildFile; fileRef = {link("file:assets","Assets.xcassets")}; }};')
b.append('/* End PBXBuildFile section */')
# File refs
b.append('\n/* Begin PBXFileReference section */')
for fname in files:
 b.append(f'\t\t{link("file:"+fname,fname)} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {fname}; sourceTree = "<group>"; }};')
b.append(f'\t\t{link("file:assets","Assets.xcassets")} = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')
b.append(f'\t\t{link("file:plist","Info.plist")} = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
b.append(f'\t\t{link("product","AetherXR.app")} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = AetherXR.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
b.append('/* End PBXFileReference section */')
# Frameworks phase
b.append('\n/* Begin PBXFrameworksBuildPhase section */')
b.append(f'\t\t{link("phase:frameworks","Frameworks")} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};')
b.append('/* End PBXFrameworksBuildPhase section */')
# groups
b.append('\n/* Begin PBXGroup section */')
b.append(f'''\t\t{link("group:root","Root")} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = ({link("group:sources","AetherXR")}, {link("group:products","Products")},);
\t\t\tsourceTree = "<group>";
\t\t}};''')
children=', '.join([link('file:'+n,n) for n in files]+[link('file:assets','Assets.xcassets'),link('file:plist','Info.plist')])
b.append(f'''\t\t{link("group:sources","AetherXR")} = {{isa = PBXGroup; children = ({children},); path = AetherXR; sourceTree = "<group>"; }};''')
b.append(f'''\t\t{link("group:products","Products")} = {{isa = PBXGroup; children = ({link("product","AetherXR.app")},); name = Products; sourceTree = "<group>"; }};''')
b.append('/* End PBXGroup section */')
# Target
b.append('\n/* Begin PBXNativeTarget section */')
b.append(f'''\t\t{link("target","AetherXR")} = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {link("configs:target","Build configuration list for PBXNativeTarget")};
\t\t\tbuildPhases = ({link("phase:sources","Sources")}, {link("phase:frameworks","Frameworks")}, {link("phase:resources","Resources")},);
\t\t\tbuildRules = ();
\t\t\tdependencies = ();
\t\t\tname = AetherXR;
\t\t\tproductName = AetherXR;
\t\t\tproductReference = {link("product","AetherXR.app")};
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};''')
b.append('/* End PBXNativeTarget section */')
# project
b.append('\n/* Begin PBXProject section */')
b.append(f'''\t\t{link("project","Project object")} = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1500; TargetAttributes = {{ {ident("target")} = {{ CreatedOnToolsVersion = 15.0; }}; }}; }};
\t\t\tbuildConfigurationList = {link("configs:project","Build configuration list for PBXProject")};
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = pt;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (pt, en, Base,);
\t\t\tmainGroup = {link("group:root","Root")};
\t\t\tproductRefGroup = {link("group:products","Products")};
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = ({link("target","AetherXR")},);
\t\t}};''')
b.append('/* End PBXProject section */')
# resource phase
b.append('\n/* Begin PBXResourcesBuildPhase section */')
b.append(f'\t\t{link("phase:resources","Resources")} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({link("build:assets","Assets.xcassets in Resources")},); runOnlyForDeploymentPostprocessing = 0; }};')
b.append('/* End PBXResourcesBuildPhase section */')
# sources phase
b.append('\n/* Begin PBXSourcesBuildPhase section */')
b.append(f'\t\t{link("phase:sources","Sources")} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+', '.join(link('build:'+n,n+' in Sources') for n in files)+',); runOnlyForDeploymentPostprocessing = 0; };')
b.append('/* End PBXSourcesBuildPhase section */')
# configurations
b.append('\n/* Begin XCBuildConfiguration section */')
for typ in ['project','target']:
 for config in ['Debug','Release']:
  key=link(f'{typ}:{config}',config)
  if typ=='project':
   opts={'ALWAYS_SEARCH_USER_PATHS':'NO','CLANG_ENABLE_MODULES':'YES','GCC_C_LANGUAGE_STANDARD':'gnu17','IPHONEOS_DEPLOYMENT_TARGET':'17.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0'}
  else:
   opts={'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','CODE_SIGN_STYLE':'Automatic',
        'CURRENT_PROJECT_VERSION':'1','GENERATE_INFOPLIST_FILE':'NO','INFOPLIST_FILE':'AetherXR/Info.plist',
        'IPHONEOS_DEPLOYMENT_TARGET':'17.0','LD_RUNPATH_SEARCH_PATHS':'("$(inherited)", "@executable_path/Frameworks")',
        'MARKETING_VERSION':'0.1.0','PRODUCT_BUNDLE_IDENTIFIER':'dev.samuel.aetherxr','PRODUCT_NAME':'"$(TARGET_NAME)"',
        'SUPPORTED_PLATFORMS':'"iphoneos iphonesimulator"','SWIFT_VERSION':'5.0',
        'SWIFT_EMIT_LOC_STRINGS':'YES','TARGETED_DEVICE_FAMILY':'1'}
   if config=='Debug':opts['SWIFT_OPTIMIZATION_LEVEL']='"-Onone"'
   else:opts['SWIFT_OPTIMIZATION_LEVEL']='"-O"'
  settings=' '.join(f'{k} = {v};' for k,v in opts.items())
  b.append(f'\t\t{key} = {{isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = {config}; }};')
b.append('/* End XCBuildConfiguration section */')
# config lists
b.append('\n/* Begin XCConfigurationList section */')
for kind in ['target','project']:
 b.append(f'\t\t{link("configs:"+kind,"Build configuration list")} = {{isa = XCConfigurationList; buildConfigurations = ({link(kind+":Debug","Debug")}, {link(kind+":Release","Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
b.append('/* End XCConfigurationList section */')
b.append('\t};')
b.append(f'\trootObject = {link("project","Project object")};')
b.append('}')
(p/'project.pbxproj').write_text('\n'.join(b)+'\n')
print('Generated',p/'project.pbxproj', 'with',len(files),'source files')
