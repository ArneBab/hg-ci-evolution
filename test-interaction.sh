#!/usr/bin/env bash

set -x

echo "use deterministic output"
export HGPLAIN=1
export HGMERGE=internal:merge-other

echo "first cleanup the world"
rm -rf evolve/ dev1/ dev2/ jenkins/ changegrouphook.sh

echo "then get evolve, and caching it."
if [ ! -e evolve-cached.bundle ]; then
    hg clone https://www.mercurial-scm.org/repo/evolve/
    hg -R evolve bundle --all evolve-cached.bundle
else
    hg clone evolve-cached.bundle evolve    
fi

export PYTHONPATH="$(realpath evolve)/hgext3rd"

echo "setup jenkins"
hg init jenkins
(cd jenkins; echo -e "[extensions]\nevolve =" >> .hg/hgrc)
cat > changegrouphook.sh <<EOF
 #!/bin/sh
hg log --template '{node}\n' -r $HG_NODE: >> unprocessed_commits.log
EOF
chmod +x changegrouphook.sh
(cd jenkins; echo -e "[hooks]\nchangegroup.run = ../changegrouphook.sh" >> .hg/hgrc)
(cd jenkins; echo -e "[phases]\npublish = False" >> .hg/hgrc)

echo "start the repo"
(cd jenkins; echo 1 > 1; hg ci -A -m "1"; hg phase --draft --force -r 0; hg phase)

echo "setup developer repos"
for i in dev1 dev2; do
    hg clone jenkins $i
    (cd $i; echo -e "[extensions]\nevolve =\nrebase =\n[ui]\nusername = $i\nmerge-tool = internal:merge-local[phase]publish = False" >> .hg/hgrc)    
done




echo "basic interaction: dev1 works, dev1 pushes"
(cd dev1; echo abc > testfile; hg ci -A -m abc; hg push; hg log --graph)

echo "jenkins checks the changes, accepts them."
(cd jenkins; hg phase --public -r tip; rm unprocessed_commits.log)

echo "dev2 pulls, pulls with rebase (keeps changes), pushes"
(cd dev2; echo cde >> testfile; hg ci -A -m cde; hg pull --rebase; hg push; hg log --graph)

echo "dev1 does more work which won’t create conflicts and has to pull, but does not push yet"
(cd dev1; echo dev1-x >> unconflicted; hg ci -A -m dev1-x; hg log --graph; hg push || hg pull --rebase ; hg log --graph)

echo "jenkins checks changes: cde is bad"
echo "for this prototype let’s just assume that the commit failed to build"
(cd jenkins; for i in $(tac unprocessed_commits.log); do hg prune -r $i && (echo "to dev2: commit $i was contained in a failing build. It has been pruned. Please graft and fix it and push again." && echo $i >> ../dev2/failing_commits.log); hg evolve; done; hg log --graph)

echo "dev1 pushes, the push succeeds, because the local hg does not know about the pruning"
(cd dev1; hg push ; hg log --graph)

echo "dev2 does some more work and tries to push, but since the bad commits leading to the good change from dev1 were removed, this would push orphan changesets, so the push fails."
(cd dev2; echo efg > foo; hg ci -A -m efg; hg pull --rebase; hg push; hg log --graph)

echo "dev2 evolves the repo and only has the good changes left."
(cd dev2; hg evolve --any; hg push; hg log --graph)

echo "now dev2 receives the mails to graph the commits."
# TODO: bug: graft does not respect HGMERGE
(cd dev2; for i in $(tac failing_commits.log); do hg graft --tool internal:merge-local --hidden $i; done; hg log --graph)

echo "dev2 fixes the commit and pushes"
(cd dev2; echo abc > testfile; hg ci -A -m "fix: cde should be abc"; hg push; hg log --graph)

echo "jenkins checks the new changes and accepts them."
(cd jenkins; hg phase --public -r tip; rm unprocessed_commits.log; hg log --graph)

echo "local result: the jenkins repository is as if dev2 had pushed after dev1-x and had fixed the change before pushing"

echo "now dev1 pulls and gets the data about obsoletes"
# TODO: bug: hg pull -u does not update to the new tip
(cd dev1; hg pull; hg log --graph)
echo "dev1 can fix this automatically with evolve, or have evolve do it automatically as part of rebase"
# (cd dev1; hg evolve --any; hg log --graph)
(cd dev1; hg rollback; hg pull --rebase; hg log --graph)

echo "global result: now all developers see a history in which dev2 committed after dev1 and fixed the bad commit before pushing"
