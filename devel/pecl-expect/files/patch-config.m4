--- config.m4.orig	2015-09-18 04:38:36 UTC
+++ config.m4
@@ -38,7 +38,7 @@ if test "$PHP_EXPECT" != "no"; then
     AC_MSG_ERROR([not found])
   fi
 
-  PHP_ADD_LIBRARY_WITH_PATH(tcl$TCL_VERSION, $TCL_PREFIX/$PHP_LIBDIR, EXPECT_SHARED_LIBADD)
+  PHP_ADD_LIBRARY_WITH_PATH(tcl$TCL_MAJOR_VERSION$TCL_MINOR_VERSION, $TCL_PREFIX/$PHP_LIBDIR, EXPECT_SHARED_LIBADD)
   PHP_ADD_LIBRARY_WITH_PATH(expect, $LIBEXPECT_DIR/$PHP_LIBDIR, EXPECT_SHARED_LIBADD)
   PHP_ADD_INCLUDE($LIBEXPECT_INCLUDE_DIR)
 