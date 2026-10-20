require 'spec_helper'

RSpec.describe Neutraliser::GainPlan do
  let(:profile) { Neutraliser::Profiles::LIVING_ROOM } # -20 LUFS, -1.5 dBTP

  def plan_for(input_i:, input_tp:, limit_db: 0.0)
    measured = Neutraliser::Measurement.new(input_i: input_i, input_tp: input_tp, input_lra: 5.0,
                                            input_thresh: -30.0, target_offset: 0.0)
    described_class.for(measured, profile, limit_db: limit_db)
  end

  it 'applies the full gap to target when the peak headroom allows it' do
    plan = plan_for(input_i: -25.0, input_tp: -20.0)

    expect(plan).to have_attributes(applied: 5.0, shortfall: 0.0, limited: false, mode: 'linear')
    expect(plan.filter).to eq('volume=5.00dB')
  end

  it 'caps the gain at the true-peak headroom and reports the shortfall' do
    plan = plan_for(input_i: -33.0, input_tp: -3.0)

    expect(plan).to have_attributes(applied: 1.5, shortfall: 11.5, limited: false)
  end

  describe 'with a limiter allowance' do
    it 'lets gain exceed the headroom by limit_db and adds an alimiter under the ceiling' do
      plan = plan_for(input_i: -26.0, input_tp: -3.0, limit_db: 4.0)

      expect(plan).to have_attributes(applied: 5.5, limited: true, mode: 'limited', shortfall: 0.5)
      expect(plan.filter).to eq('volume=5.50dB,alimiter=limit=0.7943:attack=5:release=50:level=0:latency=1')
    end

    it 'stays plain constant gain when the headroom already covers the gap' do
      plan = plan_for(input_i: -25.0, input_tp: -20.0, limit_db: 4.0)

      expect(plan).to have_attributes(applied: 5.0, limited: false)
      expect(plan.filter).not_to include('alimiter')
    end
  end

  describe '#worthwhile?' do
    it 'needs at least min_gain dB towards target' do
      expect(plan_for(input_i: -26.0, input_tp: -2.0).worthwhile?(1.0)).to be(false) # capped to +0.5
      expect(plan_for(input_i: -26.0, input_tp: -0.5).worthwhile?(1.0)).to be(false)
      expect(plan_for(input_i: -26.0, input_tp: -3.0).worthwhile?(1.0)).to be(true)  # +1.5
    end

    it 'rejects turning a quiet file down because its peaks sit over the ceiling' do
      plan = plan_for(input_i: -28.0, input_tp: 0.5)

      expect(plan.applied).to eq(-2.0)
      expect(plan.worthwhile?(1.0)).to be(false)
    end

    it 'accepts turning a loud file down' do
      expect(plan_for(input_i: -14.0, input_tp: -6.0).worthwhile?(1.0)).to be(true)
    end
  end
end
