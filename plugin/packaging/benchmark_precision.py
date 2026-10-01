"""Measure held-out ten-trial mean error, never simulator-vs-game accuracy."""
import json
from statistics import mean
from native import ROOT, run_tool
from build_worker import OUTPUT
from pck import build_archive, project_entries, read_entry, encode_project, variant

def summarize(report):
    assert not report['failures'], report['failures']
    values, cases = [], []
    for case in report['cases']:
        reference, heldout = case['samples']
        ref = [mean(x[m] for x in reference) for m in range(2)]
        errors = []
        for i in range(0, len(heldout), 10):
            batch = heldout[i:i+10]
            assert len(batch) == 10
            for m in range(2):
                estimate = mean(x[m] for x in batch)
                if ref[m] > 1e-9:
                    errors.append(abs(estimate-ref[m])/ref[m]*100)
                elif abs(estimate) > 1e-9:
                    raise ValueError('Zero reference with nonzero held-out metric')
        assert errors
        cases.append({k:case[k] for k in ('name','mode','class','round')} | {'reference_rates': ref, 'mean_error_percent': mean(errors), 'max_error_percent':max(errors)})
        values.append(mean(errors))
    assert len(cases) == 12
    return {'schema':1,'game_version':report['rules']['game_version'],'horizon':15,'batch_size':10,
            'reference_trials_per_case':100,'heldout_trials_per_case':100,'cases':cases,
            'mean_error_percent':mean(values), 'trial_count':len(cases)*200,
            'method':'Equal-weight case mean absolute percentage error of ten-trial output and recovery rates against independent 100-trial reference means; zero/zero channels excluded. Six historical builds replayed under current rules in dummy and mirrored-opponent modes. Sampling variation only; not accuracy against live game or a confidence bound.'}

def main():
    work=ROOT/'data/local_runtime/precision';work.mkdir(parents=True,exist_ok=True)
    source=OUTPUT/'BackpackLabWorker.pck'
    settings=project_entries(read_entry(source,'res://project.binary'))
    settings['autoload/BackpackLab']=variant('*res://BackpackLab/Precision.gd')
    settings['application/config/custom_user_dir_name']=variant('BackpackLabPrecision')
    pack=work/'precision.pck'
    build_archive(source,pack,{'res://project.binary':encode_project(settings),
        'res://BackpackLab/Precision.gd':(ROOT/'plugin/tests/precision.gd').read_bytes(),
        'res://BackpackLab/precision-cases.json':(work/'cases.json').read_bytes()})
    result=run_tool([OUTPUT/'BackpackLabWorker.exe','--no-window','--audio-driver','Dummy','--main-pack',pack],name='precision',timeout=3600)
    profile=work/'profile/BackpackLabPrecision'
    log=(profile/'logs/godot.log').read_text(encoding='utf-8',errors='replace')
    assert result.returncode==0 and 'SCRIPT ERROR:' not in log, log[-3000:]
    report=json.loads((profile/'report.json').read_text(encoding='utf-8'))
    summary=summarize(report)
    (work/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(summary,ensure_ascii=False,indent=2))

if __name__=='__main__':main()
