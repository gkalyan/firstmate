import json,sys
# mkfx.py <out-prefix> <head> <mergeStateStatus> <name|conclusion|required>...
out,head,state=sys.argv[1],sys.argv[2],sys.argv[3]
rollup=[];req=[]
for spec in sys.argv[4:]:
    name,concl,required=spec.rsplit("|",2)
    rollup.append({"__typename":"CheckRun","name":name,"status":"COMPLETED","conclusion":concl,
                   "startedAt":"2026-09-20T10:00:00Z","completedAt":"2026-09-20T10:05:00Z"})
    req.append({"__typename":"CheckRun","name":name,"isRequired":required=="true"})
view={"state":"OPEN","isDraft":False,"mergeable":"MERGEABLE","mergeStateStatus":state,
      "headRefOid":head,"baseRefName":"main","statusCheckRollup":rollup}
open(out+".view.json","w").write(json.dumps(view)+"\n")
required={"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"oid":head,
  "statusCheckRollup":{"contexts":{"pageInfo":{"hasNextPage":False},"nodes":req}}}}]}}}}}
open(out+".required.json","w").write(json.dumps(required)+"\n")
