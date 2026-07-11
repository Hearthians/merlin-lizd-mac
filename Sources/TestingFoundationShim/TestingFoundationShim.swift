// The standalone Command Line Tools installation ships Testing.framework's
// Foundation cross-import overlay without its Modules directory. This empty
// module keeps Swift Testing usable until a full Xcode toolchain is installed.
public enum TestingFoundationShim {}
