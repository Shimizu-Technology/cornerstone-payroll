"""Malformed or stale metadata and independent results never authorize deployment."""
import base64
from copy import deepcopy
import hashlib
import json
import unittest

import pair_evidence as evidence
import test_pair_gate as fixtures
PAYROLL_SHA, AIRE_SHA = fixtures.PAYROLL_SHA, fixtures.AIRE_SHA


class EvidenceTest(unittest.TestCase):
    def setUp(self):
        fixture = fixtures.PairGateTest()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        self.model = fixture.model
        self.root = fixture.root
        self.run = self.model['candidates']['cornerstone-payroll']['run']
        self.row = {**self.run, 'created_at': '2026-10-03T09:00:00Z'}

    def pages(self, rows, key='workflow_runs'):
        return [{'total_count': len(rows), key: rows[n:n+100]} for n in range(0,max(1,len(rows)),100)]

    def test_latest_exact_candidate_can_be_on_later_page(self):
        rows = [{**self.row, 'id': n+1} for n in range(101)]
        rows[-1]['created_at']='2026-10-04T09:00:00Z'
        self.assertEqual(evidence.latest_run(self.pages(rows),'quality.yml','push',sha=PAYROLL_SHA),101)

    def test_incomplete_changed_duplicate_or_excessive_inventory_rejected(self):
        valid=self.pages([{**self.row,'id':n+1} for n in range(101)])
        invalids=[[],[{'total_count': True,'workflow_runs':[]}], valid[:1],
            [valid[0],{'total_count':102,'workflow_runs':[self.row]}],
            [valid[0],{'total_count':101,'workflow_runs':[valid[0]['workflow_runs'][0]]}],
            [{'total_count':1001,'workflow_runs':[]}], self.pages([{**self.row,'id':True}])]
        for pages in invalids:
            with self.subTest(pages=repr(pages)[:100]), self.assertRaises(ValueError):
                evidence.inventory(pages,'workflow_runs')

    def test_foreign_or_malformed_run_inventory_rejected(self):
        for key,value in [('path','.github/workflows/other.yml'),('event','pull_request'),
                ('head_branch','main'),('head_sha','f'*40),('head_sha','main'),
                ('run_attempt',True),('run_attempt',0),('created_at','yesterday')]:
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):
                evidence.latest_run(self.pages([{**self.row,key:value}]),'quality.yml','push',sha=PAYROLL_SHA)

    def test_pending_newest_is_selected_and_fails_success_gate(self):
        pending={**self.row,'id':202,'created_at':'2026-10-04T09:00:00Z','status':'queued','conclusion':None}
        self.assertEqual(evidence.latest_run(self.pages([self.row,pending]),'quality.yml','push',sha=PAYROLL_SHA),202)
        with self.assertRaises(ValueError): evidence.verify_run(pending,'quality.yml','push',202,sha=PAYROLL_SHA)

    def test_current_attempt_jobs_are_bound_and_required_exactly_once(self):
        jobs=[{'id':n+1,'run_id':self.run['id'],'run_attempt':1,'head_sha':PAYROLL_SHA,'head_branch':'staging-v2',
            'name':name,'status':'completed','conclusion':'success'} for n,name in enumerate(evidence.REQUIRED_JOBS['cornerstone-payroll'])]
        evidence.verify_jobs(self.pages(jobs,'jobs'),'cornerstone-payroll',self.run)
        for key,value in [('run_id',99),('run_attempt',2),('run_attempt',True),('head_sha','f'*40),('head_branch','main'),('conclusion','skipped')]:
            wrong=deepcopy(jobs);wrong[-1][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):
                evidence.verify_jobs(self.pages(wrong,'jobs'),'cornerstone-payroll',self.run)
        duplicate=[*jobs,{**jobs[-1],'id':99}]
        with self.assertRaises(ValueError): evidence.verify_jobs(self.pages(duplicate,'jobs'),'cornerstone-payroll',self.run)

    def test_recheck_rejects_changed_attempt_or_state(self):
        evidence.unchanged(self.run,dict(self.run))
        for key,value in [('run_attempt',2),('run_attempt',True),('status','queued'),('head_sha','f'*40),('id',99)]:
            with self.subTest(key=key),self.assertRaises(ValueError): evidence.unchanged(self.run,{**self.run,key:value})

    def verify(self, result=None, certificate=None, fixture=b'fixture', driver=b'driver', update_hash=True):
        result = self.model['result'] if result is None else result
        certificate = deepcopy(self.model['certificate']) if certificate is None else certificate
        path=self.root/'independent.json'; path.write_text(json.dumps(result))
        if update_hash: certificate['independent_result_sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
        def content(data): return {'type':'file','encoding':'base64','size':len(data),'content':base64.b64encode(data).decode()}
        evidence.verify_certificate(self.model['run'],certificate,path,PAYROLL_SHA,AIRE_SHA,content(fixture),content(driver))

    def test_schema2_independent_result_passes(self):
        self.verify()

    def test_legacy_unknown_extra_and_mistyped_certificate_fields_rejected(self):
        for patch in [{'schema_version':1},{'schema_version':3},{'extra':'anything'},{'run_attempt':True},{'aire_sha':'f'*40}]:
            with self.subTest(patch=patch),self.assertRaises(ValueError): self.verify(certificate={**self.model['certificate'],**patch})

    def test_result_hash_is_of_exact_artifact_bytes(self):
        result=deepcopy(self.model['result']);result['gross']='1187.50'
        with self.assertRaises(ValueError):self.verify(result=result,update_hash=False)

    def test_missing_failed_non_http_foreign_or_operator_result_rejected(self):
        for key,value in [('schema_version',2),('payroll_sha','f'*40),('passed',False),('passed',1),
                ('synthetic_only',False),('actual_http_transport',False),('actual_operator_acceptance',True),
                ('source','aire'),('exact_issued_lines',True),('gross','1187.49'),('extra','unknown')]:
            with self.subTest(key=key),self.assertRaises(ValueError):self.verify(result={**self.model['result'],key:value})

    def test_trusted_revision_fixture_and_driver_hashes_required(self):
        for kwargs in [{'fixture':b'changed'},{'driver':b'changed'}]:
            with self.subTest(kwargs=kwargs),self.assertRaises(ValueError):self.verify(**kwargs)

    def test_policy_capabilities_and_receipt_totals_are_explicit(self):
        for key,value in [('capabilities',self.model['result']['capabilities'][:-1]),('hours',{'total':45,'regular':45,'overtime':0}),
                ('independent_policy',{**self.model['result']['independent_policy'],'cutoff_at':'2026-10-14T17:00:00+10:00'}),
                ('independent_policy',{**self.model['result']['independent_policy'],'cutoff_rule':'previous_regular_pay_date'}),
                ('independent_policy',{**self.model['result']['independent_policy'],'schedule_version':True})]:
            with self.subTest(key=key),self.assertRaises(ValueError):self.verify(result={**self.model['result'],key:value})

    def test_duplicate_json_and_oversize_file_rejected(self):
        path=self.root/'bad.json'
        path.write_text('{"passed":true,"passed":false}')
        with self.assertRaises(ValueError): evidence.load(path)
        path.write_text('x'*100)
        with self.assertRaises(ValueError): evidence.load(path,limit=99)

    def test_trusted_content_requires_complete_base64_file(self):
        for value in [{'type':'file','encoding':'base64','size':3,'content':'eA=='},
                      {'type':'file','encoding':'base64','size':1,'content':'!invalid!'}]:
            with self.assertRaises(ValueError): evidence.content_digest(value)


if __name__=='__main__':unittest.main()
