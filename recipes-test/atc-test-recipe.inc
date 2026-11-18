# Required by every recipe under recipes-test/. Never require it from a
# product recipe.
#
# The fault recipes make bundles that RAUC accepts: they are signed with the
# build's RAUC_KEY_FILE and carry its compatible string. Their slot panics,
# hangs or holds no kernel. layer.conf's BBFILES glob matches recipes-test/, so
# without this file a product build dir (`bitbake world`, for example) can make
# such a bundle with the product's keys.
#
# So each of these recipes is skipped unless the build dir opts in with
#   ATC_TEST_RECIPES = "1"
# in local.conf or auto.conf. scripts/qemu-rauc-proof.sh writes it. Set it only
# in a build dir that signs with test keys.
#
# A skip and not a BBMASK: anonymous python runs after local.conf is read, and
# `bitbake atc-bundle-panic` then prints the reason below instead of "Nothing
# PROVIDES".

ATC_TEST_RECIPES ??= ""

python () {
    if d.getVar('ATC_TEST_RECIPES') != '1':
        raise bb.parse.SkipRecipe(
            "a fault-injection test recipe. Set ATC_TEST_RECIPES = \"1\" in "
            "local.conf to build it, and only in a build dir that signs with "
            "test keys. scripts/qemu-rauc-proof.sh sets it.")
}
