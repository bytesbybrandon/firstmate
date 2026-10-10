#!/usr/bin/env bash
# Project pathname and validation-remote checks for spawn, relaunch and refresh.
# fm_project_canonical_dir prints an existing directory's stored spelling,
# resolving symlinks and case aliases without lowercasing distinct directories.
# pwd -P and realpath alone retain caller casing on case-insensitive WSL mounts.
# fm_project_validation_remote_check is read-only: when a no-mistakes remote
# exists, its effective fetch and push targets must name the staging directory
# resolved by `no-mistakes status` from this checkout. Missing or unreadable
# resolution refuses; neither registrations nor remotes are repaired here.

# shellcheck source=bin/fm-nm-run-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-nm-run-lib.sh"

fm_project_canonical_dir() {  # <existing-directory>
  [ -d "$1" ] || return 1
  LC_ALL=C perl -MCwd=realpath -e '
    my $path = realpath($ARGV[0]);
    defined($path) or exit 1;
    my $parent = "/";
    for my $part (split m{/}, $path) {
      next if $part eq "";
      opendir(my $dir, $parent) or exit 1;
      my @names = readdir($dir);
      closedir($dir);
      my @matches = grep { $_ eq $part } @names;
      if (!@matches) {
        my @want = stat("$parent/$part");
        @want or exit 1;
        @matches = grep {
          my $candidate = "$parent/$_";
          my @have = stat($candidate);
          $_ ne "." && $_ ne ".." && !-l $candidate && @have
            && $want[0] == $have[0] && $want[1] == $have[1]
        } @names;
      }
      @matches == 1 or exit 1;
      $parent =~ s{/$}{};
      $parent .= "/$matches[0]";
    }
    print "$parent\n";
  ' "$1" 2>/dev/null
}

fm_project_validation_remote_check() {  # <checkout-root>
  local project=$1 remotes fetch_urls push_urls output gate url target
  remotes=$(git -C "$project" remote) || {
    echo "error: cannot inspect validation remotes in $project" >&2
    return 1
  }
  case $'\n'"$remotes"$'\n' in
    *$'\nno-mistakes\n'*) ;;
    *) return 0 ;;
  esac
  if ! fetch_urls=$(git -C "$project" remote get-url --all no-mistakes) \
     || ! push_urls=$(git -C "$project" remote get-url --push --all no-mistakes); then
    echo "error: cannot resolve no-mistakes fetch and push remotes in $project" >&2
    return 1
  fi
  if ! output=$(NO_COLOR=1 TERM=dumb fm_nm_run_bounded "$project" 10 status 2>&1); then
    echo "error: cannot resolve validation staging repository in $project; run no-mistakes status there to inspect the refusal" >&2
    return 1
  fi
  gate=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*gate:[[:space:]]*//p')
  if [ -z "$gate" ] || [[ "$gate" == *$'\n'* ]] \
     || ! gate=$(cd -- "$project" && fm_project_canonical_dir "$gate"); then
    echo "error: no-mistakes status in $project did not resolve one existing validation staging repository; inspect its registration before launching or refreshing" >&2
    return 1
  fi
  while IFS= read -r url; do
    target=$url
    case "$url" in
      file:///*) target=${url#file://} ;;
      file://localhost/*) target=${url#file://localhost} ;;
    esac
    if [ -z "$target" ] || ! (cd -- "$project" && [ "$target" -ef "$gate" ]); then
      echo "error: validation remote disagreement in $project: no-mistakes target '$url' differs from resolved staging repository '$gate'; reconcile the existing registration and remote before launching or refreshing (nothing repaired)" >&2
      return 1
    fi
  done <<< "$fetch_urls
$push_urls"
}
