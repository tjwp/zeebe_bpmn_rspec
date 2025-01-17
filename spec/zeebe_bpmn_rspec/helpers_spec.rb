# frozen_string_literal: true

require "securerandom"
require "active_support"
require "active_support/core_ext/hash/keys"

RSpec.describe ZeebeBpmnRspec::Helpers do
  let(:path) { File.join(__dir__, "../fixtures/#{bpmn_name}.bpmn") }
  let(:bpmn_name) { "one_task" }
  let(:deploy) { true }

  before { deploy_workflow(path) if deploy }

  describe "#deploy_workflow" do
    let(:deploy) { false }

    it "can deploy a workflow" do
      response = deploy_workflow(path)

      workflow = response.workflows.find do |wf|
        wf.resourceName == "#{bpmn_name}.bpmn"
      end
      expect(workflow).not_to be_nil
    end

    context "when a name is specified" do
      let(:name) { SecureRandom.hex }

      it "deploys the workflow with that name" do
        response = deploy_workflow(path, name)

        workflow = response.workflows.find do |wf|
          wf.resourceName == "#{name}.bpmn"
        end
        expect(workflow).not_to be_nil
      end
    end
  end

  describe "#with_workflow_instance" do
    it "can run a workflow instance" do
      key = nil
      with_workflow_instance("one_task") do |workflow_instance_key|
        key = workflow_instance_key
      end

      expect(key).to eq(workflow_instance_key)
    end

    it "can start and stop a workflow without requiring a block" do
      expect do
        with_workflow_instance("one_task")
      end.not_to raise_error
    end
  end

  describe "#workflow_complete!" do
    it "can assert that a workflow is complete" do
      with_workflow_instance("one_task") do
        activate_job("do_something").and_complete

        workflow_complete!
      end
    end
  end

  describe "#activate_job" do
    it "can activate a job" do
      with_workflow_instance("one_task", { input: 1 }) do
        job = activate_job("do_something")

        expect(job.variables).to eq("input" => 1)
        expect(job.headers).to eq("what_to_do" => "nothing")
      end
    end

    it "can activate a job with a specific worker" do
      with_workflow_instance("one_task") do
        worker = "my-worker-#{SecureRandom.hex}"
        job = activate_job("do_something", worker: worker)

        expect(job.raw.worker).to eq(worker)
      end
    end

    it "does not allow a job to be activated with a nil worker" do
      expect do
        with_workflow_instance("one_task") do
          job = activate_job("do_something", worker: nil, validate: false)

          expect(job.raw).to be_nil
        end
      end.to raise_error(ArgumentError, "'worker' cannot be blank")
    end

    it "does not allow a job to be activated with a blank worker" do
      expect do
        with_workflow_instance("one_task") do
          job = activate_job("do_something", worker: "", validate: false)

          expect(job.raw).to be_nil
        end
      end.to raise_error(ArgumentError, "'worker' cannot be blank")
    end

    it "times out after the globally configured time" do
      allow(ZeebeBpmnRspec).to receive(:activate_request_timeout).and_return(100) # ms
      with_workflow_instance("one_task", { input: 1 }) do
        t1 = Time.now
        job = activate_job("do_nothing", validate: false)
        t2 = Time.now

        expect(job.job).to be_nil
        expect(t2 - t1).to be < 0.5 # much less than the default value of 1 second
      end
    end

    it "can activate a job with specific variables" do
      with_workflow_instance("one_task", { a: 1, b: 2 }) do
        job = activate_job("do_something", fetch_variables: :a)

        expect(job).to have_variables("a" => 1)
      end
    end

    it "can activate a job with a missing variable" do
      with_workflow_instance("one_task", { a: 1, b: 2 }) do
        job = activate_job("do_something", fetch_variables: "c")

        expect(job).to have_variables({})
      end
    end

    it "can activate a job with multiple variables" do
      with_workflow_instance("one_task", { a: 1, b: 2, c: 3 }) do
        job = activate_job("do_something", fetch_variables: %w(b c))

        expect(job).to have_variables("b" => 2, "c" => 3)
      end
    end
  end

  describe "ActivatedJob#workflow_instance_key" do
    it "exposes the workflow instance key for a job" do
      with_workflow_instance("one_task") do
        job = activate_job("do_something")

        expect(job.workflow_instance_key).to eq(workflow_instance_key)
      end
    end
  end

  describe "ActivatedJob#expect_input" do
    it "can check the variables for a job" do
      with_workflow_instance("one_task", { a: 99, b: "c" }) do
        activate_job("do_something").expect_input(a: 99, b: "c")
      end
    end
  end

  describe "ActivatedJob#expect_headers" do
    it "can check the headers for a job" do
      with_workflow_instance("one_task", { a: 99, b: "c" }) do
        activate_job("do_something").expect_headers(what_to_do: "nothing")
      end
    end
  end

  describe "ActivatedJob#and_complete" do
    it "can complete a job" do
      with_workflow_instance("one_task") do
        activate_job("do_something").and_complete

        workflow_complete!
      end
    end

    context "when new variables are specified" do
      let(:bpmn_name) { :two_tasks }

      it "can complete a job with new variables" do
        with_workflow_instance("two_tasks") do
          activate_job("do_something").
            and_complete(return: (value = SecureRandom.hex))

          activate_job("next_step").
            expect_input(return: value)
        end
      end
    end
  end

  describe "ActivatedJob#and_fail" do
    it "can fail a job" do
      with_workflow_instance("one_task") do
        activate_job("do_something").
          and_fail(retries: 1)

        activate_job("do_something").and_complete

        workflow_complete!
      end
    end

    it "can fail a job with a message" do
      with_workflow_instance("one_task") do
        activate_job("do_something").
          and_fail("foobar", retries: 1)

        activate_job("do_something").and_complete

        workflow_complete!
      end
    end
  end

  describe "ActivatedJob#update_retries" do
    it "can update the retries for a job" do
      with_workflow_instance("one_task") do
        job = job_with_type("do_something")
        job.fail(retries: 1)

        job.update_retries(3)

        new_job = job_with_type("do_something")
        expect(new_job.retries).to eq(3)
        new_job.complete

        workflow_complete!
      end
    end
  end

  describe "ActivatedJob#and_throw_error" do
    it "can throw an error for a job" do
      with_workflow_instance("one_task") do
        job = activate_job("do_something")

        job.throw_error("ERROR_BOOM")

        # should fail since there was already an error
        expect do
          job.fail("boo!")
        end.to raise_error(/in state 'ERROR_THROWN'/)
      end
    end

    it "can throw an error for a job with an error message" do
      with_workflow_instance("one_task") do
        activate_job("do_something").
          and_throw_error("ERROR_BOOM", "chickaboom")
      end
    end
  end

  describe "#activate_jobs" do
    let(:bpmn_name) { "parallel_tasks" }

    it "can activate multiple jobs" do
      with_workflow_instance("parallel_tasks") do
        activate_job("do_something").and_complete

        jobs = activate_jobs("parallel", max_jobs: 2).to_a

        job_one = jobs.find { |job| job.headers["branch"] == "one" }
        job_two = jobs.find { |job| job.headers["branch"] == "two" }

        expect(job_one).not_to be nil
        expect(job_two).not_to be nil

        jobs.map(&:complete)

        workflow_complete!
      end
    end

    it "can activate jobs with specific variables" do
      with_workflow_instance("parallel_tasks", { a: 1, b: 2, c: 3 }) do
        activate_job("do_something").and_complete

        jobs = activate_jobs("parallel", fetch_variables: %i(a b), max_jobs: 2).to_a

        expect(jobs).to all(have_variables("a" => 1, "b" => 2))
      end
    end
  end

  describe "#publish_message" do
    let(:bpmn_name) { :message_receive }

    it "can publish a message" do
      with_workflow_instance("message_receive", expected_message_key: (key = SecureRandom.uuid)) do
        publish_message("expected_message", correlation_key: key)

        workflow_complete!
      end
    end

    it "can publish a message with a ttl" do
      with_workflow_instance("message_receive", expected_message_key: (key = SecureRandom.uuid)) do
        publish_message("expected_message", correlation_key: key, ttl_ms: 1000)

        workflow_complete!
      end
    end
  end

  describe "#set_variables" do
    it "sets variables for a workflow" do
      with_workflow_instance("one_task", var: "initial") do
        set_variables(workflow_instance_key, { var: "updated", new: 1 })

        expect(job_with_type("do_something")).to have_activated.
          with_variables(var: "updated", new: 1).and_complete

        workflow_complete!
      end
    end

    context "task scope" do
      let(:bpmn_name) { "two_tasks" }

      it "can set variables for a task" do
        with_workflow_instance(bpmn_name, var: "initial") do
          job = job_with_type("do_something")
          job.fail(retries: 1)

          set_variables(job.task_key, { var: "updated", new: 1 })

          expect(job_with_type("do_something")).to have_activated.
            with_variables(var: "updated", new: 1).and_complete

          expect(job_with_type("next_step")).to have_activated.
            with_variables(var: "initial").and_complete

          workflow_complete!
        end
      end

      it "can set variables with non-local scope" do
        with_workflow_instance(bpmn_name, var: "initial") do
          job = job_with_type("do_something")
          job.fail(retries: 1)

          set_variables(job.task_key, { var: "updated", new: 1 }, local: false)

          expect(job_with_type("do_something")).to have_activated.
            with_variables(var: "updated", new: 1).and_complete

          expect(job_with_type("next_step")).to have_activated.
            with_variables(var: "updated", new: 1).and_complete

          workflow_complete!
        end
      end
    end
  end
end
