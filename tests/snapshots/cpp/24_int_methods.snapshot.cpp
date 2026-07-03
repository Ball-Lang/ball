
namespace {


} // namespace

int main() {
    auto n = BallDyn(static_cast<int64_t>(12345));
    std::cout << ball_to_string(ball_to_string(n)) << std::endl;
    std::cout << ball_to_string(ball_to_string([](BallDyn _v) -> BallDyn { if(_v.type()==typeid(int64_t))return BallDyn(std::abs(static_cast<int64_t>(_v))); return BallDyn(std::abs(static_cast<double>(_v))); }(n))) << std::endl;
    std::cout << ball_to_string(ball_to_string([](BallDyn _v) -> BallDyn { if(_v.type()==typeid(int64_t))return BallDyn(std::abs(static_cast<int64_t>(_v))); return BallDyn(std::abs(static_cast<double>(_v))); }((-n)))) << std::endl;
    std::cout << ball_to_string(ball_to_string([&](int64_t _a, int64_t _b){ auto _r = _a % _b; return _r < 0 ? _r + (_b < 0 ? -_b : _b) : _r; }(static_cast<int64_t>(static_cast<int64_t>(7)), static_cast<int64_t>(static_cast<int64_t>(3))))) << std::endl;
    std::cout << ball_to_string(ball_to_string((static_cast<int64_t>(7) / static_cast<int64_t>(3)))) << std::endl;
    return 0;
}
