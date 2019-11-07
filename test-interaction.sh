#!/usr/bin/env bash

set -x

# use deterministic output
export HGPLAIN=1
export HGMERGE=internal:merge-other

# first cleanup the world
rm -rf evolve/ dev1/ dev2/ jenkins/ changegrouphook.sh

# then get evolve, and caching it.
if [ ! -e evolve-cached.bundle ]; then
    hg clone https://www.mercurial-scm.org/repo/evolve/
    hg -R evolve bundle --all evolve-cached.bundle
else
    hg clone evolve-cached.bundle evolve    
fi

export PYTHONPATH="$(realpath evolve)/hgext3rd"

# setup jenkins
hg init jenkins
(cd jenkins; echo -e "[extensions]\nevolve =" >> .hg/hgrc)
cat > changegrouphook.sh <<EOF
 #!/bin/sh
hg log --template '{node}\n' -r $HG_NODE: >> unprocessed_commits.log
EOF
chmod +x changegrouphook.sh
(cd jenkins; echo -e "[hooks]\nchangegroup.run = ../changegrouphook.sh" >> .hg/hgrc)
(cd jenkins; echo -e "[phases]\npublish = False" >> .hg/hgrc)

# start the repo
(cd jenkins; echo 1 > 1; hg ci -A -m "1"; hg phase --draft --force -r 0; hg phase)

# setup developer repos
for i in dev1 dev2; do
    hg clone jenkins $i
    (cd $i; echo -e "[extensions]\nevolve =\nrebase =\n[ui]merge-tool = internal:merge-local[phase]publish = False" >> .hg/hgrc)    
done

# basic interaction: dev1 works, dev2 works, dev1 pushes
(cd dev1; echo abc > testfile; hg ci -A -m abc; hg push; hg log --graph)

# jenkins checks the changes, accepts them.
(cd jenkins; hg phase --public; rm unprocessed_commits.log)

# dev2 pulls, pulls with rebase (keeps changes), pushes
(cd dev2; echo cde >> testfile; hg ci -A -m cde; hg pull --rebase; hg push; hg log --graph)

# jenkins checks changes: cde is bad
# for this prototype let’s just assume that the commit failed to build
(cd jenkins; for i in $(tac unprocessed_commits.log); do hg prune -r $i; echo "to dev2: commit $i was contained in a failing build. It has been pruned. Please graft and fix it and push again."; hg evolve; echo $i >> ../dev2/failing_commits.log; done)

# dev1 does more work which won’t create conflicts and has to pull
(cd dev1; echo dev1-x >> unconflicted; hg ci -A -m dev1-x; hg push || hg pull --rebase ; hg push)

# dev2 does some more work and tries to push, but since the bad commits leading to the good change from dev1 were removed, this would push orphan changesets, so the push fails.
(cd dev2; echo efg > foo; hg ci -A -m efg; hg pull --rebase; hg push; hg log --graph)
# dev2 evolves the repo and only has the good changes left.
(cd dev2; hg evolve --any; hg push; hg log --graph)
# now dev2 receives the mails to graph the commits.
# TODO: bug in mercurial: graft does not respect HGMERGE
(cd dev2; for i in $(tac failing_commits.log); do hg graft --tool internal:merge-local --hidden $i; done; hg log --graph)
# dev2 fixes the commit and pushes
(cd dev2; echo abc > testfile; hg ci -A -m "fix: should be abc"; hg push; hg log --graph)

